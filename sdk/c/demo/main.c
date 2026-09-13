/*
 * A C consumer: links what `zig build c` stages and drives the ABI's
 * renderer-free slice end to end. The GPU path needs a real renderer the host
 * library does not carry, so it prints that status rather than asserting.
 */

#include <gosslens.h>

#include <stdio.h>
#include <string.h>

#define CHECK(expr)                                                        \
    do {                                                                   \
        goss_status _s = (expr);                                           \
        if (_s != GOSS_OK) {                                               \
            fprintf(stderr, "%s -> status %d\n", #expr, (int)_s);          \
            return 1;                                                      \
        }                                                                  \
    } while (0)

int main(void) {
    /* Any-thread, and the first call an embedder makes. The engine compares the
     * major, rather than every embedder writing the comparison itself. */
    uint32_t abi = goss_abi_version();
    printf("abi %u.%u\n", abi >> 16, abi & 0xffffu);
    CHECK(goss_abi_check(GOSS_ABI_VERSION));

    /* What a lens asks for against what this build has, answered before activating
     * anything. A catalogue filters on this instead of activating to find out. */
    static const char wants_face[] =
        "{\"glf\":\"1.0\",\"id\":\"x\",\"version\":\"1.0.0\",\"display_name\":\"x\","
        "\"engine_compat\":\">=0.5\",\"capabilities\":[\"face\"],\"parameters\":[],"
        "\"nodes\":[],\"triggers\":[]}";
    uint64_t missing = 0;
    CHECK(goss_lens_capabilities_missing((const uint8_t *)wants_face, sizeof(wants_face) - 1, &missing));
    printf("a lens wanting face tracking is missing %llu\n", (unsigned long long)missing);

    goss_engine *engine = NULL;
    CHECK(goss_engine_create(NULL, &engine));

    goss_session *session = NULL;
    CHECK(goss_session_create(engine, NULL, &session));

    /* Pure helpers: no engine state, no renderer. */
    float yuv[16];
    CHECK(goss_color_yuv_to_rgb(GOSS_COLOR_BT709, GOSS_COLOR_RANGE_VIDEO, yuv));

    const float root[3] = {0.0f, 0.0f, 0.0f};
    const float target[3] = {1.0f, 0.0f, 0.0f};
    const float pole[3] = {0.0f, 1.0f, 0.0f};
    float mid[3], end[3];
    CHECK(goss_solve_two_bone_ik(root, 0.6f, 0.6f, target, pole, mid, end));
    printf("ik mid (%.3f, %.3f, %.3f)\n", mid[0], mid[1], mid[2]);

    /* Camera controls are declarative intent the engine normalizes and stores;
     * the SDK reads them back and drives the platform camera. */
    goss_camera_controls controls;
    memset(&controls, 0, sizeof(controls));
    controls.focus_mode = 1; /* locked */
    controls.zoom_factor = 2.0f;
    CHECK(goss_session_set_camera_controls(session, &controls));
    goss_camera_controls read_back;
    CHECK(goss_session_camera_controls(session, &read_back));
    if (read_back.focus_mode != 1) {
        fprintf(stderr, "camera controls did not round-trip\n");
        return 1;
    }
    printf("zoom %.2f\n", read_back.zoom_factor);

    /* The app-driven multi-face path: the caller runs its own tracker (or the
     * platform's) and submits faces; the core keeps the ones with presence and
     * landmarks. No inference stack needed. */
    goss_face_result face;
    memset(&face, 0, sizeof(face));
    face.presence = 1.0f;
    face.landmark_count = GOSS_FACE_LANDMARK_COUNT;
    CHECK(goss_session_submit_faces(session, &face, 1));
    uint32_t face_count = 0;
    CHECK(goss_session_face_count(session, &face_count));
    if (face_count != 1) {
        fprintf(stderr, "expected 1 kept face, got %u\n", face_count);
        return 1;
    }
    goss_face_result kept;
    CHECK(goss_session_face_result_at(session, 0, &kept));
    printf("faces %u presence %.2f\n", face_count, kept.presence);

    /* The degradation policy: report a frame time and thermal state, take the
     * level the next frame runs at. */
    goss_degrade_level level =
        goss_session_report_frame(session, 12000, GOSS_THERMAL_NOMINAL);
    printf("degrade level %d\n", (int)level);

    /* What this session has done, read through the header's own struct: the
     * model rail's plan is the one number that says whether inference is
     * steady or still growing its buffer. */
    goss_session_report report;
    CHECK(goss_session_read_report(session, &report));
    printf("frames %llu, model plan %llu bytes, %u growths\n",
           (unsigned long long)report.frames_submitted,
           (unsigned long long)report.ml_plan_bytes,
           report.ml_plan_growths);

    /* Named geofences: several regions alongside the default one, each firing
     * geo.in_region('name') on-device. Only that boolean crosses the rail. */
    const uint8_t venue[] = "venue";
    CHECK(goss_session_set_named_geofence(session, venue, sizeof(venue) - 1,
                                          37.7749, -122.4194, 250.0));
    CHECK(goss_session_clear_named_geofences(session));

    /* The model allowlist: pin a bring-your-own tracker or segmenter to its
     * 32-byte SHA-256 digest before the worker is enabled, then clear it. */
    uint8_t digest[32];
    memset(digest, 0xab, sizeof(digest));
    CHECK(goss_session_allow_model_digest(session, digest));
    CHECK(goss_session_clear_model_allowlist(session));

    /* Multi-source composition: register a named RGBA source, matte it from its
     * own alpha, and stack it full-frame over the camera. No renderer needed to
     * hold the composition state; a platform build draws it. */
    const uint8_t guest[] = "guest";
    CHECK(goss_session_define_source(session, guest, sizeof(guest) - 1));
    CHECK(goss_session_set_source_composite(session, guest, sizeof(guest) - 1,
                                            0.85f, 1, 0.0f, 0.0f, 0.0f, 0.0f));
    CHECK(goss_session_set_layout(session, 5)); /* overlay */
    CHECK(goss_session_clear_layout(session));
    CHECK(goss_session_remove_source(session, guest, sizeof(guest) - 1));

    /* Spatial state: submit the room, then ask it the questions an agent asks. The
     * planes and anchors are the host's to provide; everything below answers over
     * whatever was last submitted. */
    const float flat[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    goss_world_plane planes[2];
    memset(planes, 0, sizeof(planes));
    memcpy(planes[0].pose, flat, sizeof(flat));
    planes[0].id = 10;
    planes[0].extent_x = 4.0f;
    planes[0].extent_z = 4.0f;
    planes[0].classification = 1; /* floor */
    memcpy(planes[1].pose, flat, sizeof(flat));
    planes[1].id = 20;
    planes[1].pose[13] = 0.75f; /* a table, three quarters of a metre up */
    planes[1].extent_x = 1.2f;
    planes[1].extent_z = 0.8f;
    planes[1].classification = 4; /* table */
    goss_world_state world_state;
    memset(&world_state, 0, sizeof(world_state));
    world_state.tracking_state = 2;
    memcpy(world_state.world_from_camera, flat, sizeof(flat));
    memcpy(world_state.projection, flat, sizeof(flat));
    CHECK(goss_session_submit_world(session, &world_state, planes, 2, NULL, 0, NULL));

    uint64_t floor_id = 0;
    CHECK(goss_session_floor_plane(session, &floor_id));
    printf("floor_plane -> plane %llu\n", (unsigned long long)floor_id);

    goss_footprint cup = { 0.1f, 0.1f, 0.12f };
    goss_placement spots[4];
    size_t spot_count = 0;
    CHECK(goss_session_place_on(session, &cup, NULL, 0, spots, 4, &spot_count));
    printf("place_on -> %zu surfaces, best is plane %llu with %.3f still free\n",
           spot_count, (unsigned long long)spots[0].plane_id, spots[0].free_fraction);

    const float from[3] = { 0.0f, 0.0f, 0.0f };
    const float to[3] = { 3.0f, 4.0f, 0.0f };
    float metres = 0.0f, sigma = 0.0f;
    uint32_t known = 0;
    CHECK(goss_session_measure_between(session, from, 0.01f, to, 0.02f, &metres, &sigma, &known));
    printf("measure_between -> %.4f m, sigma %.4f, vouched %u\n", metres, sigma, known);

    /* Scope: narrow to everything except drawing, then draw, so the refusal names a
     * permission a host can grant rather than a capability that does not exist. It
     * only ever narrows, which is why widening needs a new session. */
    uint32_t verbs = 0xFFFFFFFFu & ~(1u << GOSS_VERB_ANNOTATE);
    CHECK(goss_session_set_scope(session, goss_perception_select_all(), verbs));
    goss_annotation box;
    memset(&box, 0, sizeof(box));
    box.id = 1;
    box.opacity = 1.0f;
    goss_status drew = goss_session_annotate(session, &box, NULL, 0);
    uint8_t verb_name[32];
    size_t verb_len = 0;
    goss_scope_verb_name(GOSS_VERB_ANNOTATE, verb_name, sizeof(verb_name), &verb_len);
    printf("annotate out of scope -> status %d, the verb it wanted is \"%.*s\" of %u\n",
           (int)drew, (int)verb_len, (const char *)verb_name, goss_scope_verb_count());

    /* The GPU path, called honestly against the host stub. */
    goss_status render = goss_engine_render_frame(engine, session);
    printf("render_frame -> status %d (host has no renderer)\n", (int)render);

    goss_session_destroy(session);
    goss_engine_destroy(engine);
    printf("ok\n");
    return 0;
}
