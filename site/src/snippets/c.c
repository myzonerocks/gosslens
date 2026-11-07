#include <gosslens.h>

/* The version is the first call any binding makes; a major mismatch is fatal. */
if ((goss_abi_version() >> 16) != GOSS_ABI_MAJOR) return;

goss_engine *engine = NULL;
goss_engine_config engine_config = { .texture_pool_capacity = 8 };
if (goss_engine_create(&engine_config, &engine) != GOSS_OK) return;

goss_session *session = NULL;
goss_session_config session_config = { .frame_budget_us = 8000 };
goss_session_create(engine, &session_config, &session);
goss_session_activate_lens(session, manifest, manifest_len);
