#include "postgres.h"

#include <limits.h>

#include "fmgr.h"
#include "miscadmin.h"

#include "access/htup_details.h"
#include "catalog/pg_language_d.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "common/hashfn.h"
#include "executor/executor.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "optimizer/planner.h"
#include "parser/parse_clause.h"
#include "parser/parse_oper.h"
#include "tcop/utility.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/plancache.h"
#include "utils/syscache.h"

PG_MODULE_MAGIC;

#define PG_DISORDER_VERSION "0.1.0"

void _PG_init(void);

typedef enum
{
  PG_DISORDER_MODE_OFF = 0,
  PG_DISORDER_MODE_REVERSE,
  PG_DISORDER_MODE_SHUFFLE
} PgDisorderMode;

static const struct config_enum_entry pg_disorder_mode_options[] = {
  {"off", PG_DISORDER_MODE_OFF, false},
  {"reverse", PG_DISORDER_MODE_REVERSE, false},
  {"shuffle", PG_DISORDER_MODE_SHUFFLE, false},
  {NULL, 0, false}
};

static int  pg_disorder_mode = PG_DISORDER_MODE_OFF;
static int  pg_disorder_seed = 0;
static bool pg_disorder_force_serial = true;
static char *pg_disorder_version = NULL;

static int  pg_disorder_session_seed = 0;
static bool pg_disorder_session_seed_chosen = false;

static int  pg_disorder_nesting_level = 0;

static planner_hook_type prev_planner_hook = NULL;
static ExecutorRun_hook_type prev_ExecutorRun_hook = NULL;
static ExecutorFinish_hook_type prev_ExecutorFinish_hook = NULL;
static ProcessUtility_hook_type prev_ProcessUtility_hook = NULL;
static needs_fmgr_hook_type prev_needs_fmgr_hook = NULL;
static fmgr_hook_type prev_fmgr_hook = NULL;

static int
pg_disorder_pick_seed(void)
{
  uint64    z = (uint64) MyStartTimestamp ^ ((uint64) MyProcPid << 32);

  z = (z ^ (z >> 30)) * UINT64CONST(0xBF58476D1CE4E5B9);
  z = (z ^ (z >> 27)) * UINT64CONST(0x94D049BB133111EB);
  z ^= z >> 31;
  return (int) (z % (uint32) INT_MAX) + 1;
}


static int
pg_disorder_base_seed(void)
{
  if (pg_disorder_seed != 0)
    return pg_disorder_seed;

  if (!pg_disorder_session_seed_chosen)
  {
    pg_disorder_session_seed = pg_disorder_pick_seed();
    pg_disorder_session_seed_chosen = true;
    ereport(LOG,
        (errmsg("pg_disorder %s: session seed = %d "
            "(replay with SET pg_disorder.seed = %d)",
            PG_DISORDER_VERSION,
            pg_disorder_session_seed, pg_disorder_session_seed)));
  }

  return pg_disorder_session_seed;
}

static int64
pg_disorder_statement_seed(int base, const char *sourceText)
{
  uint64  z = (uint64) (uint32) base;

  if (sourceText != NULL)
    z ^= ((uint64) hash_bytes((const unsigned char *) sourceText,
                  (int) strlen(sourceText))) << 32;

  z = (z ^ (z >> 30)) * UINT64CONST(0xBF58476D1CE4E5B9);
  z = (z ^ (z >> 27)) * UINT64CONST(0x94D049BB133111EB);
  z ^= z >> 31;

  return (int64) z;
}

static void
pg_disorder_replan_bool(bool newval, void *extra)
{
  ResetPlanCache();
}

static void
pg_disorder_replan_int(int newval, void *extra)
{
  ResetPlanCache();
}

static bool
pg_disorder_row_marks_walker(Node *node, void *context)
{
  if (node == NULL)
    return false;

  if (IsA(node, Query))
  {
    Query    *query = (Query *) node;

    if (query->rowMarks != NIL)
      return true;

    return query_tree_walker(query, pg_disorder_row_marks_walker, context, 0);
  }

  return expression_tree_walker(node, pg_disorder_row_marks_walker, context);
}

static bool
pg_disorder_is_eligible(Query *parse)
{
  return pg_disorder_mode != PG_DISORDER_MODE_OFF
    && pg_disorder_nesting_level == 0
    && parse->commandType == CMD_SELECT
    && parse->utilityStmt == NULL
    && parse->sortClause == NIL
    && parse->setOperations == NULL
    && parse->distinctClause == NIL
    && parse->groupClause == NIL
    && parse->groupingSets == NIL
    && !parse->hasAggs
    && !parse->hasWindowFuncs
    && !parse->hasRecursive
    && parse->jointree != NULL
    && parse->jointree->fromlist != NIL
    && !pg_disorder_row_marks_walker((Node *) parse, NULL);
}

static void
pg_disorder_append_sort_key(Query *parse, Expr *expr, Oid exprType,
              bool descending)
{
  TargetEntry *tle;
  SortGroupClause *sgc;
  Oid      ltop;
  Oid      gtop;
  Oid      eqop;
  bool    hashable;

  tle = makeTargetEntry(expr,
            (AttrNumber) (list_length(parse->targetList) + 1),
            NULL,
            true);
  parse->targetList = lappend(parse->targetList, tle);

  get_sort_group_operators(exprType,
               !descending, true, descending,
               &ltop, &eqop, &gtop,
               &hashable);

  sgc = makeNode(SortGroupClause);
  sgc->tleSortGroupRef = assignSortGroupRef(tle, parse->targetList);
  sgc->eqop = eqop;
  sgc->sortop = descending ? gtop : ltop;
#if PG_VERSION_NUM >= 180000
  /* sortop is a greater-than operator exactly when we want descending order */
  sgc->reverse_sort = descending;
#endif
  sgc->nulls_first = false;
  sgc->hashable = hashable;

  parse->sortClause = lappend(parse->sortClause, sgc);
}

static Expr *
pg_disorder_row_number(Query *parse)
{
  WindowClause *wc;
  WindowFunc *wf;

  wc = makeNode(WindowClause);
  wc->frameOptions = FRAMEOPTION_DEFAULTS;
  wc->winref = list_length(parse->windowClause) + 1;
  parse->windowClause = lappend(parse->windowClause, wc);

  wf = makeNode(WindowFunc);
  wf->winfnoid = F_ROW_NUMBER;
  wf->wintype = INT8OID;
  wf->winref = wc->winref;
  wf->location = -1;
  parse->hasWindowFuncs = true;

  return (Expr *) wf;
}

/* reverse: ORDER BY row_number() OVER () DESC */
static void
pg_disorder_add_reverse_sort(Query *parse)
{
  pg_disorder_append_sort_key(parse, pg_disorder_row_number(parse),
                INT8OID, true);
}

static void
pg_disorder_add_shuffle_sort(Query *parse, int64 seed)
{
  Const    *seedConst;
  Expr     *rownum;
  FuncExpr *mixed;

  seedConst = makeConst(INT8OID, -1, InvalidOid, sizeof(int64),
             Int64GetDatum(seed), false, FLOAT8PASSBYVAL);

  rownum = pg_disorder_row_number(parse);

  mixed = makeFuncExpr(F_HASHINT8EXTENDED, INT8OID,
             list_make2(rownum, seedConst),
             InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);

  pg_disorder_append_sort_key(parse, (Expr *) mixed, INT8OID, false);
}

static PlannedStmt *
pg_disorder_planner(Query *parse, const char *query_string,
        int cursorOptions, ParamListInfo boundParams
#if PG_VERSION_NUM >= 190000
        , ExplainState *es
#endif
        )
{
  PlannedStmt *volatile result = NULL;

  if (pg_disorder_is_eligible(parse))
  {
    parse = copyObject(parse);

    if (pg_disorder_mode == PG_DISORDER_MODE_REVERSE)
      pg_disorder_add_reverse_sort(parse);
    else
      pg_disorder_add_shuffle_sort(parse,
                     pg_disorder_statement_seed(
                       pg_disorder_base_seed(),
                       query_string));

    if (pg_disorder_force_serial)
      cursorOptions &= ~CURSOR_OPT_PARALLEL_OK;
  }

  pg_disorder_nesting_level++;
  PG_TRY();
  {
#if PG_VERSION_NUM >= 190000
#define PG_DISORDER_PLANNER_ARGS parse, query_string, cursorOptions, boundParams, es
#else
#define PG_DISORDER_PLANNER_ARGS parse, query_string, cursorOptions, boundParams
#endif
    if (prev_planner_hook)
      result = prev_planner_hook(PG_DISORDER_PLANNER_ARGS);
    else
      result = standard_planner(PG_DISORDER_PLANNER_ARGS);
#undef PG_DISORDER_PLANNER_ARGS
  }
  PG_FINALLY();
  {
    pg_disorder_nesting_level--;
  }
  PG_END_TRY();

  return result;
}

#if PG_VERSION_NUM >= 180000
static void
pg_disorder_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count)
{
  pg_disorder_nesting_level++;
  PG_TRY();
  {
    if (prev_ExecutorRun_hook)
      prev_ExecutorRun_hook(queryDesc, direction, count);
    else
      standard_ExecutorRun(queryDesc, direction, count);
  }
  PG_FINALLY();
  {
    pg_disorder_nesting_level--;
  }
  PG_END_TRY();
}
#else
static void
pg_disorder_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count,
          bool execute_once)
{
  pg_disorder_nesting_level++;
  PG_TRY();
  {
    if (prev_ExecutorRun_hook)
      prev_ExecutorRun_hook(queryDesc, direction, count, execute_once);
    else
      standard_ExecutorRun(queryDesc, direction, count, execute_once);
  }
  PG_FINALLY();
  {
    pg_disorder_nesting_level--;
  }
  PG_END_TRY();
}
#endif

static void
pg_disorder_ExecutorFinish(QueryDesc *queryDesc)
{
  pg_disorder_nesting_level++;
  PG_TRY();
  {
    if (prev_ExecutorFinish_hook)
      prev_ExecutorFinish_hook(queryDesc);
    else
      standard_ExecutorFinish(queryDesc);
  }
  PG_FINALLY();
  {
    pg_disorder_nesting_level--;
  }
  PG_END_TRY();
}

static bool
pg_disorder_execute_evaluates_params(Node *stmt)
{
  if (stmt != NULL && IsA(stmt, Query))
    stmt = ((Query *) stmt)->utilityStmt;

  return stmt != NULL
    && IsA(stmt, ExecuteStmt)
    && ((ExecuteStmt *) stmt)->params != NIL;
}

static bool
pg_disorder_utility_runs_top_level_query(Node *stmt)
{
  switch (nodeTag(stmt))
  {
    case T_CreateTableAsStmt:
      return !pg_disorder_execute_evaluates_params(
                ((CreateTableAsStmt *) stmt)->query);
    case T_ExplainStmt:
      return !pg_disorder_execute_evaluates_params(
                ((ExplainStmt *) stmt)->query);
    case T_ExecuteStmt:
      return !pg_disorder_execute_evaluates_params(stmt);
    case T_RefreshMatViewStmt:
    case T_DeclareCursorStmt:
    case T_PrepareStmt:
      return true;
    case T_CopyStmt:
      return !((CopyStmt *) stmt)->is_from;
    default:
      return false;
  }
}

static void
pg_disorder_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
               bool readOnlyTree, ProcessUtilityContext context,
               ParamListInfo params, QueryEnvironment *queryEnv,
               DestReceiver *dest, QueryCompletion *qc)
{
  Node     *stmt = pstmt->utilityStmt;
  volatile bool nested = stmt != NULL
    && !pg_disorder_utility_runs_top_level_query(stmt);

  if (nested)
    pg_disorder_nesting_level++;

  PG_TRY();
  {
    if (prev_ProcessUtility_hook)
      prev_ProcessUtility_hook(pstmt, queryString, readOnlyTree, context,
                   params, queryEnv, dest, qc);
    else
      standard_ProcessUtility(pstmt, queryString, readOnlyTree, context,
                  params, queryEnv, dest, qc);
  }
  PG_FINALLY();
  {
    if (nested)
      pg_disorder_nesting_level--;
  }
  PG_END_TRY();
}

static bool
pg_disorder_needs_fmgr_hook(Oid fn_oid)
{
  HeapTuple  tuple;
  Oid      lang;
  bool    needed;

  if (prev_needs_fmgr_hook && prev_needs_fmgr_hook(fn_oid))
    return true;

  tuple = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn_oid));
  if (!HeapTupleIsValid(tuple))
    return false;

  lang = ((Form_pg_proc) GETSTRUCT(tuple))->prolang;
  needed = lang != INTERNALlanguageId
    && lang != ClanguageId
    && lang != SQLlanguageId;

  ReleaseSysCache(tuple);

  return needed;
}

static void
pg_disorder_fmgr_hook(FmgrHookEventType event, FmgrInfo *flinfo, Datum *arg)
{
  switch (event)
  {
    case FHET_START:
      pg_disorder_nesting_level++;
      break;
    case FHET_END:
    case FHET_ABORT:
      if (pg_disorder_nesting_level > 0)
        pg_disorder_nesting_level--;
      break;
  }

  if (prev_fmgr_hook)
    prev_fmgr_hook(event, flinfo, arg);
}

void
_PG_init(void)
{
  DefineCustomEnumVariable("pg_disorder.mode",
               "How to perturb top-level SELECTs that lack ORDER BY.",
               "off leaves queries untouched. reverse appends a "
               "deterministic reversal of the row order. shuffle appends "
               "a seeded pseudorandom permutation. Both surface implicit "
               "row-order assumptions; reverse is reproducible without a "
               "seed. Intended for test databases only.",
               &pg_disorder_mode,
               PG_DISORDER_MODE_OFF,
               pg_disorder_mode_options,
               PGC_USERSET,
               0,
               NULL, pg_disorder_replan_int, NULL);

  DefineCustomIntVariable("pg_disorder.seed",
              "Seed for reproducible shuffling (0 = auto + log).",
              "0 picks a random seed once per session and logs it, "
              "so a failure can be replayed by SET pg_disorder.seed to "
              "the logged value. Any non-zero value is used as-is. "
              "Each statement derives its own seed from this one and its "
              "query text, so a statement can be replayed on its own.",
              &pg_disorder_seed,
              0,
              INT_MIN, INT_MAX,
              PGC_USERSET,
              0,
              NULL, pg_disorder_replan_int, NULL);

  DefineCustomBoolVariable("pg_disorder.force_serial",
               "Plan perturbed queries serially so that their row order "
               "is reproducible.",
               "The injected sort key is built on a window function, which "
               "is parallel-restricted, so a parallel plan feeds it in "
               "worker-arrival order and the same input yields a different "
               "row order on every run -- defeating both a pinned seed "
               "(shuffle) and reverse's determinism. Turning this off "
               "restores parallelism and gives that up.",
               &pg_disorder_force_serial,
               true,
               PGC_USERSET,
               0,
               NULL, pg_disorder_replan_bool, NULL);

  DefineCustomStringVariable("pg_disorder.version",
              "pg_disorder version.",
              NULL,
              &pg_disorder_version,
              PG_DISORDER_VERSION,
              PGC_INTERNAL,
              GUC_NOT_IN_SAMPLE | GUC_DISALLOW_IN_FILE,
              NULL, NULL, NULL);

#if PG_VERSION_NUM >= 150000
  MarkGUCPrefixReserved("pg_disorder");
#else
  EmitWarningsOnPlaceholders("pg_disorder");
#endif

  prev_planner_hook = planner_hook;
  planner_hook = pg_disorder_planner;

  prev_ExecutorRun_hook = ExecutorRun_hook;
  ExecutorRun_hook = pg_disorder_ExecutorRun;

  prev_ExecutorFinish_hook = ExecutorFinish_hook;
  ExecutorFinish_hook = pg_disorder_ExecutorFinish;

  prev_ProcessUtility_hook = ProcessUtility_hook;
  ProcessUtility_hook = pg_disorder_ProcessUtility;

  prev_needs_fmgr_hook = needs_fmgr_hook;
  needs_fmgr_hook = pg_disorder_needs_fmgr_hook;

  prev_fmgr_hook = fmgr_hook;
  fmgr_hook = pg_disorder_fmgr_hook;
}
