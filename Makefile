MODULES = pg_disorder

REGRESS = pg_disorder

ifndef NO_TAP
TAP_TESTS = 1
endif

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
