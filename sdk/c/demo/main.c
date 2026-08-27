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
    /* Any-thread, and the first call an embedder makes. A major mismatch is a
     * refusal to run, not a warning. */
    uint32_t abi = goss_abi_version();
    printf("abi %u.%u\n", abi >> 16, abi & 0xffffu);
    if ((abi >> 16) != GOSS_ABI_MAJOR) {
        fprintf(stderr, "abi major mismatch: built %u, linked %u\n",
                GOSS_ABI_MAJOR, abi >> 16);
        return 1;
    }

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

    /* The GPU path, called honestly against the host stub. */
    goss_status render = goss_engine_render_frame(engine, session);
    printf("render_frame -> status %d (host has no renderer)\n", (int)render);

    goss_session_destroy(session);
    goss_engine_destroy(engine);
    printf("ok\n");
    return 0;
}
