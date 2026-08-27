// Compiled -fno-exceptions (build.zig joltFlags sets the flag for this
// shim and the Jolt library), so no unwind can reach the C boundary;
// creation-path news use std::nothrow and report failure. The rigid-body
// world for lens content behind a C surface; no Jolt type escapes.

#include <Jolt/Jolt.h>

#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemSingleThreaded.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyInterface.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/CylinderShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/ConvexHullShape.h>
#include <Jolt/Physics/Collision/Shape/MeshShape.h>
#include <Jolt/Physics/Constraints/DistanceConstraint.h>
#include <Jolt/Physics/Constraints/PointConstraint.h>
#include <Jolt/Physics/Constraints/FixedConstraint.h>
#include <Jolt/Physics/Constraints/HingeConstraint.h>
#include <Jolt/Physics/Constraints/SpringSettings.h>
#include <Jolt/Physics/Body/BodyLock.h>
#include <Jolt/Physics/Body/BodyLockMulti.h>
#include <Jolt/Physics/SoftBody/SoftBodyCreationSettings.h>
#include <Jolt/Physics/SoftBody/SoftBodySharedSettings.h>
#include <Jolt/Physics/SoftBody/SoftBodyMotionProperties.h>
#include <Jolt/Physics/Hair/Hair.h>
#include <Jolt/Physics/Hair/HairSettings.h>
#include <Jolt/Physics/Hair/HairShaders.h>
#include <Jolt/Physics/Hair/RegisterHair.h>
#include <Jolt/Compute/CPU/ComputeSystemCPU.h>
#include <Jolt/Shaders/HairWrapper.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <atomic>
#include <cmath>
#include <cstdarg>
#include <initializer_list>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <utility>
#include <vector>

namespace {

// Two layers: static scenery and moving bodies.
constexpr JPH::ObjectLayer layer_static = 0;
constexpr JPH::ObjectLayer layer_moving = 1;
constexpr JPH::BroadPhaseLayer bp_static(0);
constexpr JPH::BroadPhaseLayer bp_moving(1);

class BpLayers final : public JPH::BroadPhaseLayerInterface {
 public:
  JPH::uint GetNumBroadPhaseLayers() const override { return 2; }
  JPH::BroadPhaseLayer GetBroadPhaseLayer(JPH::ObjectLayer layer) const override {
    return layer == layer_static ? bp_static : bp_moving;
  }
};

class ObjectVsBp final : public JPH::ObjectVsBroadPhaseLayerFilter {
 public:
  bool ShouldCollide(JPH::ObjectLayer layer, JPH::BroadPhaseLayer bp) const override {
    return layer == layer_moving || bp == bp_moving;
  }
};

class ObjectPairs final : public JPH::ObjectLayerPairFilter {
 public:
  bool ShouldCollide(JPH::ObjectLayer a, JPH::ObjectLayer b) const override {
    return a == layer_moving || b == layer_moving;
  }
};

struct HairInstance {
  JPH::Ref<JPH::HairSettings> settings;
  JPH::Hair* hair = nullptr;
};

// A constraint plus the two bodies it references, so removing either body can
// first drop the constraints that would otherwise hold a dangling Body*.
struct ConstraintRecord {
  JPH::Ref<JPH::Constraint> constraint;
  JPH::BodyID a;
  JPH::BodyID b;
};

// Every untrusted creation scalar is finite-checked before it becomes a Jolt
// object: a body born non-finite would poison the rollback guard whose own
// baseline is that first pose.
bool allFinite(std::initializer_list<float> vs) {
  for (float v : vs) if (!std::isfinite(v)) return false;
  return true;
}

// Read-boundary floor: a soft-body or hair vertex that diverged reads as zero
// rather than uploading a NaN into the mesh path.
float finiteOr0(float v) { return std::isfinite(v) ? v : 0.0f; }

// A moving body tracked for the post-substep guard. Its last finite pose is
// kept so a step that blows a velocity or position non-finite is rolled back
// rather than propagating a NaN through the world; a planar body also has its
// z and out-of-plane motion reset each substep for a stable 2D world.
struct TrackedBody {
  JPH::BodyID id;
  JPH::RVec3 last_pos;
  JPH::Quat last_rot;
  bool planar;
  float plane_z;
  int reports = 0;
};

bool poseIsFinite(JPH::RVec3Arg p, JPH::QuatArg q, JPH::Vec3Arg lv, JPH::Vec3Arg av) {
  return std::isfinite(p.GetX()) && std::isfinite(p.GetY()) && std::isfinite(p.GetZ()) &&
         std::isfinite(q.GetX()) && std::isfinite(q.GetY()) && std::isfinite(q.GetZ()) && std::isfinite(q.GetW()) &&
         std::isfinite(lv.GetX()) && std::isfinite(lv.GetY()) && std::isfinite(lv.GetZ()) &&
         std::isfinite(av.GetX()) && std::isfinite(av.GetY()) && std::isfinite(av.GetZ());
}

struct World {
  JPH::TempAllocatorImpl temp{4 * 1024 * 1024};
  JPH::JobSystemSingleThreaded jobs{JPH::cMaxPhysicsJobs};
  BpLayers bp_layers;
  ObjectVsBp object_vs_bp;
  ObjectPairs object_pairs;
  JPH::PhysicsSystem system;
  double accumulator = 0.0;
  // Lazily created on the first hair; shared across a world's hairs.
  JPH::Ref<JPH::ComputeSystemCPU> compute;
  JPH::Ref<JPH::ComputeQueue> queue;
  JPH::HairShaders hair_shaders;
  bool hair_ready = false;
  std::vector<HairInstance> hairs;
  std::vector<TrackedBody> tracked_bodies;
  std::vector<ConstraintRecord> constraints;
  int total_substeps = 0;

  // Hair objects are plain owned pointers (JPH::Hair is not refcounted);
  // pairing their delete with world teardown keeps every remaining hair
  // and its CPU-compute buffers off the floor when a session goes away.
  ~World() {
    for (auto& h : hairs) delete h.hair;
  }
};

int world_count = 0;
bool g_hair_registered = false;

// Jolt leaves its trace and assert hooks null by default; a firing assert
// would then call through null and crash. Route them to stderr instead so
// a tripped invariant is logged, not fatal - the sim continues past it.
void traceImpl(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  char buffer[1024];
  vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);
  fprintf(stderr, "jolt: %s\n", buffer);
}

#ifdef JPH_ENABLE_ASSERTS
bool assertFailedImpl(const char* expression, const char* message, const char* file, JPH::uint line) {
  fprintf(stderr, "jolt assert: %s:%u: (%s) %s\n", file, line, expression, message != nullptr ? message : "");
  return false;
}
#endif

// Jolt allocates on the C++ heap, invisible to the Zig leak gate; route its
// allocator through a counter so a leaked Jolt object (a Hair and its compute
// buffers especially) surfaces as live bytes the vendor-heap proof reads
// across a lifecycle. A prefix header records size and base for the free path.
std::atomic<size_t> g_jolt_live_bytes{0};

struct JoltBlock {
  void* base;
  size_t size;
};

void* joltCountedAlloc(size_t size, size_t alignment) {
  const size_t total = sizeof(JoltBlock) + alignment + size;
  void* base = std::malloc(total);
  if (base == nullptr) return nullptr;
  const uintptr_t raw = reinterpret_cast<uintptr_t>(base) + sizeof(JoltBlock);
  const uintptr_t user = (raw + (alignment - 1)) & ~static_cast<uintptr_t>(alignment - 1);
  JoltBlock* block = reinterpret_cast<JoltBlock*>(user) - 1;
  block->base = base;
  block->size = size;
  g_jolt_live_bytes.fetch_add(size, std::memory_order_relaxed);
  return reinterpret_cast<void*>(user);
}

void joltCountedFree(void* ptr) {
  if (ptr == nullptr) return;
  JoltBlock* block = reinterpret_cast<JoltBlock*>(ptr) - 1;
  g_jolt_live_bytes.fetch_sub(block->size, std::memory_order_relaxed);
  std::free(block->base);
}

void* joltAllocate(size_t size) { return joltCountedAlloc(size, 16); }
void joltFree(void* ptr) { joltCountedFree(ptr); }
void* joltAlignedAllocate(size_t size, size_t alignment) { return joltCountedAlloc(size, alignment); }
void joltAlignedFree(void* ptr) { joltCountedFree(ptr); }

void* joltReallocate(void* block, size_t old_size, size_t new_size) {
  if (block == nullptr) return joltCountedAlloc(new_size, 16);
  void* fresh = joltCountedAlloc(new_size, 16);
  if (fresh == nullptr) return nullptr;
  std::memcpy(fresh, block, old_size < new_size ? old_size : new_size);
  joltCountedFree(block);
  return fresh;
}

// Jolt classes override operator new without a nothrow form, so OOM
// there cannot come back as null. Allocates through the same Jolt
// allocator branch the class operator delete will free, then
// placement-constructs; null means the caller reports failure.
template <typename T, typename... A>
T* nothrowNew(A&&... args) {
  void* memory = alignof(T) > __STDCPP_DEFAULT_NEW_ALIGNMENT__
                     ? JPH::AlignedAllocate(sizeof(T), alignof(T))
                     : JPH::Allocate(sizeof(T));
  if (memory == nullptr) return nullptr;
  return new (memory) T(std::forward<A>(args)...);
}

// Registers a created constraint with the system and records it against its
// two bodies. A null constraint (creation failed) is ignored.
void add_constraint(World* world, JPH::Constraint* constraint, JPH::BodyID a, JPH::BodyID b) {
  if (constraint == nullptr) return;
  world->system.AddConstraint(constraint);
  world->constraints.push_back({JPH::Ref<JPH::Constraint>(constraint), a, b});
}

}  // namespace

extern "C" void* goss_physics_world_create(float gravity_y) {
  if (world_count == 0 && JPH::Factory::sInstance == nullptr) {
    JPH::Allocate = joltAllocate;
    JPH::Free = joltFree;
    JPH::Reallocate = joltReallocate;
    JPH::AlignedAllocate = joltAlignedAllocate;
    JPH::AlignedFree = joltAlignedFree;
    JPH::Trace = traceImpl;
    JPH_IF_ENABLE_ASSERTS(JPH::AssertFailed = assertFailedImpl;)
    JPH::Factory::sInstance = nothrowNew<JPH::Factory>();
    if (JPH::Factory::sInstance == nullptr) return nullptr;
    JPH::RegisterTypes();
  }
  auto* world = new (std::nothrow) World();
  if (world == nullptr) return nullptr;
  world_count += 1;
  world->system.Init(1024, 0, 1024, 1024, world->bp_layers, world->object_vs_bp, world->object_pairs);
  world->system.SetGravity(JPH::Vec3(0.0f, gravity_y, 0.0f));
  return world;
}

extern "C" void goss_physics_world_destroy(void* handle) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return;
  delete world;
  world_count -= 1;
  if (world_count == 0) {
    JPH::UnregisterTypes();
    delete JPH::Factory::sInstance;
    JPH::Factory::sInstance = nullptr;
    // The hair registration lived in that Factory; the next world must
    // register hair again in the fresh one.
    g_hair_registered = false;
  }
}

// Live bytes held on the Jolt heap right now. The vendor-heap proof reads it
// between lifecycles; a value above baseline means a Jolt object outlived its
// world. Internal to the harness, not part of the public C ABI.
extern "C" size_t goss_jolt_live_bytes(void) {
  return g_jolt_live_bytes.load(std::memory_order_relaxed);
}

// Places a finished shape as a body at a pose with a surface material.
// motion: 0 static, 1 dynamic, 2 kinematic (the engine drives it). When
// planar is set the body is confined to the z = 0 plane - x/y translation
// and z spin only, a 2D world inside the 3D engine.
static uint32_t finalize_body(World* world, JPH::Ref<JPH::Shape> body_shape, float px, float py, float pz, float qx, float qy, float qz, float qw, float friction, float restitution, uint32_t motion, uint32_t planar) {
  if (world == nullptr || !allFinite({px, py, pz, qx, qy, qz, qw, friction, restitution})) return UINT32_MAX;
  const JPH::EMotionType motion_type = motion == 1   ? JPH::EMotionType::Dynamic
                                       : motion == 2 ? JPH::EMotionType::Kinematic
                                                     : JPH::EMotionType::Static;
  const bool moving = motion != 0;
  JPH::Quat rotation = JPH::Quat(qx, qy, qz, qw);
  if (rotation.LengthSq() < 1.0e-6f) rotation = JPH::Quat::sIdentity();
  rotation = rotation.Normalized();
  JPH::BodyCreationSettings settings(body_shape, JPH::RVec3(px, py, pz), rotation,
                                     motion_type, moving ? layer_moving : layer_static);
  settings.mFriction = friction;
  settings.mRestitution = restitution;
  const JPH::BodyID id = world->system.GetBodyInterface().CreateAndAddBody(
      settings, moving ? JPH::EActivation::Activate : JPH::EActivation::DontActivate);
  if (id.IsInvalid()) return UINT32_MAX;
  if (moving) world->tracked_bodies.push_back({id, JPH::RVec3(px, py, pz), rotation, planar != 0, pz});
  return id.GetIndexAndSequenceNumber();
}

// shape: 0 box (x/y/z half extents), 1 sphere (x radius), 2 cylinder
// (x radius, y half height), 3 capsule (x radius, y half height); a
// rotation can lay a capsule or cylinder on its side.
static uint32_t create_body(World* world, uint32_t shape, float px, float py, float pz, float sx, float sy, float sz, float qx, float qy, float qz, float qw, float friction, float restitution, uint32_t motion, uint32_t planar) {
  if (world == nullptr || !allFinite({sx, sy, sz})) return UINT32_MAX;
  JPH::Ref<JPH::Shape> body_shape;
  if (shape == 0) {
    body_shape = nothrowNew<JPH::BoxShape>(JPH::Vec3(sx, sy, sz));
  } else if (shape == 1) {
    body_shape = nothrowNew<JPH::SphereShape>(sx);
  } else if (shape == 2) {
    body_shape = nothrowNew<JPH::CylinderShape>(sy, sx);
  } else if (shape == 3) {
    body_shape = nothrowNew<JPH::CapsuleShape>(sy, sx);
  } else {
    return UINT32_MAX;
  }
  if (body_shape == nullptr) return UINT32_MAX;
  return finalize_body(world, body_shape, px, py, pz, qx, qy, qz, qw, friction, restitution, motion, planar);
}

// Jolt's own defaults for a body that does not name a material.
static const float default_friction = 0.2f;
static const float default_restitution = 0.0f;

// Adds a body at an identity orientation. Returns the body id, or UINT32_MAX.
extern "C" uint32_t goss_physics_body_add(void* handle, uint32_t shape, float px, float py, float pz, float sx, float sy, float sz, uint32_t motion) {
  return create_body(static_cast<World*>(handle), shape, px, py, pz, sx, sy, sz, 0, 0, 0, 1, default_friction, default_restitution, motion, 0);
}

// Adds a body rotated by a quaternion, so an elongated shape can lie on its
// side or a static collider can tilt. Returns the body id, or UINT32_MAX.
extern "C" uint32_t goss_physics_body_add_oriented(void* handle, uint32_t shape, float px, float py, float pz, float sx, float sy, float sz, float qx, float qy, float qz, float qw, uint32_t motion) {
  return create_body(static_cast<World*>(handle), shape, px, py, pz, sx, sy, sz, qx, qy, qz, qw, default_friction, default_restitution, motion, 0);
}

// Adds a body with a rotation, a surface material (friction 0 slippery ~1
// grippy, restitution 0 dead 1 bouncy), and an optional planar constraint that
// confines it to the z = 0 plane for a 2D world. Returns the body id.
extern "C" uint32_t goss_physics_body_add_material(void* handle, uint32_t shape, const float* pos, const float* size, const float* quat, float friction, float restitution, uint32_t motion, uint32_t planar) {
  if (pos == nullptr || size == nullptr || quat == nullptr) return UINT32_MAX;
  return create_body(static_cast<World*>(handle), shape, pos[0], pos[1], pos[2], size[0], size[1], size[2], quat[0], quat[1], quat[2], quat[3], friction, restitution, motion, planar);
}

// Adds a body whose collision shape is the convex hull of a set of local-space
// points (three floats each) - an arbitrary faceted collider. Returns the body
// id, or UINT32_MAX if the hull could not be built.
extern "C" uint32_t goss_physics_body_add_hull(void* handle, const float* points, uint32_t point_count, const float* pos, const float* quat, float friction, float restitution, uint32_t motion, uint32_t planar) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || points == nullptr || pos == nullptr || quat == nullptr || point_count < 4) return UINT32_MAX;
  JPH::Array<JPH::Vec3> hull_points;
  hull_points.reserve(point_count);
  for (uint32_t i = 0; i < point_count; ++i) {
    hull_points.push_back(JPH::Vec3(points[i * 3], points[i * 3 + 1], points[i * 3 + 2]));
  }
  JPH::ConvexHullShapeSettings settings(hull_points);
  JPH::ShapeSettings::ShapeResult result = settings.Create();
  if (result.HasError()) return UINT32_MAX;
  return finalize_body(world, result.Get(), pos[0], pos[1], pos[2], quat[0], quat[1], quat[2], quat[3], friction, restitution, motion, planar);
}

// Adds a static body whose collider is a concave triangle mesh: `points`
// (three floats each) and `indices` (three per triangle). Concave meshes are
// static in Jolt. Returns the body id, or UINT32_MAX on a bad mesh.
extern "C" uint32_t goss_physics_body_add_mesh(void* handle, const float* points, uint32_t point_count, const uint32_t* indices, uint32_t index_count, const float* pos, const float* quat, float friction, float restitution) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || points == nullptr || indices == nullptr || pos == nullptr || quat == nullptr || point_count < 3 || index_count < 3 || index_count % 3 != 0) return UINT32_MAX;
  JPH::VertexList vertices;
  vertices.reserve(point_count);
  for (uint32_t i = 0; i < point_count; ++i) {
    vertices.push_back(JPH::Float3(points[i * 3], points[i * 3 + 1], points[i * 3 + 2]));
  }
  JPH::IndexedTriangleList triangles;
  triangles.reserve(index_count / 3);
  for (uint32_t i = 0; i < index_count; i += 3) {
    if (indices[i] >= point_count || indices[i + 1] >= point_count || indices[i + 2] >= point_count) return UINT32_MAX;
    triangles.push_back(JPH::IndexedTriangle(indices[i], indices[i + 1], indices[i + 2], 0));
  }
  JPH::MeshShapeSettings settings(vertices, triangles);
  JPH::ShapeSettings::ShapeResult result = settings.Create();
  if (result.HasError()) return UINT32_MAX;
  return finalize_body(world, result.Get(), pos[0], pos[1], pos[2], quat[0], quat[1], quat[2], quat[3], friction, restitution, 0, 0);
}

// Links two bodies with a distance constraint between local attach
// points - the chain link for content hanging off an anchor body.
extern "C" int32_t goss_physics_constrain_distance(void* handle, uint32_t body_a, uint32_t body_b, float ax, float ay, float az, float bx, float by, float bz, float min_distance, float max_distance) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || !allFinite({ax, ay, az, bx, by, bz, min_distance, max_distance})) return -1;
  const JPH::BodyID ids[2] = {JPH::BodyID(body_a), JPH::BodyID(body_b)};
  JPH::BodyLockMultiWrite lock(world->system.GetBodyLockInterface(), ids, 2);
  JPH::Body* a = lock.GetBody(0);
  JPH::Body* b = lock.GetBody(1);
  if (a == nullptr || b == nullptr) return -1;
  JPH::DistanceConstraintSettings settings;
  settings.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
  settings.mPoint1 = JPH::RVec3(ax, ay, az);
  settings.mPoint2 = JPH::RVec3(bx, by, bz);
  settings.mMinDistance = min_distance;
  settings.mMaxDistance = max_distance;
  add_constraint(world, settings.Create(*a, *b), ids[0], ids[1]);
  return 0;
}

// Pins two bodies together at a single point (a ball joint): the point stays
// coincident while the bodies rotate freely about it - a pendulum pivot.
extern "C" int32_t goss_physics_constrain_point(void* handle, uint32_t body_a, uint32_t body_b, float ax, float ay, float az, float bx, float by, float bz) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || !allFinite({ax, ay, az, bx, by, bz})) return -1;
  const JPH::BodyID ids[2] = {JPH::BodyID(body_a), JPH::BodyID(body_b)};
  JPH::BodyLockMultiWrite lock(world->system.GetBodyLockInterface(), ids, 2);
  JPH::Body* a = lock.GetBody(0);
  JPH::Body* b = lock.GetBody(1);
  if (a == nullptr || b == nullptr) return -1;
  JPH::PointConstraintSettings settings;
  settings.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
  settings.mPoint1 = JPH::RVec3(ax, ay, az);
  settings.mPoint2 = JPH::RVec3(bx, by, bz);
  add_constraint(world, settings.Create(*a, *b), ids[0], ids[1]);
  return 0;
}

// Welds two bodies together rigidly at their current relative pose - a fixed
// joint: no relative translation or rotation, so the body rides its anchor.
extern "C" int32_t goss_physics_constrain_fixed(void* handle, uint32_t body_a, uint32_t body_b) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return -1;
  const JPH::BodyID ids[2] = {JPH::BodyID(body_a), JPH::BodyID(body_b)};
  JPH::BodyLockMultiWrite lock(world->system.GetBodyLockInterface(), ids, 2);
  JPH::Body* a = lock.GetBody(0);
  JPH::Body* b = lock.GetBody(1);
  if (a == nullptr || b == nullptr) return -1;
  JPH::FixedConstraintSettings settings;
  settings.mSpace = JPH::EConstraintSpace::WorldSpace;
  settings.mAutoDetectPoint = true;
  add_constraint(world, settings.Create(*a, *b), ids[0], ids[1]);
  return 0;
}

// Hinges two bodies at a world pivot about an axis - the body swings in the
// one plane perpendicular to the axis (a door or single-axis pendulum).
extern "C" int32_t goss_physics_constrain_hinge(void* handle, uint32_t body_a, uint32_t body_b, float px, float py, float pz, float hx, float hy, float hz) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || !allFinite({px, py, pz, hx, hy, hz})) return -1;
  const JPH::BodyID ids[2] = {JPH::BodyID(body_a), JPH::BodyID(body_b)};
  JPH::BodyLockMultiWrite lock(world->system.GetBodyLockInterface(), ids, 2);
  JPH::Body* a = lock.GetBody(0);
  JPH::Body* b = lock.GetBody(1);
  if (a == nullptr || b == nullptr) return -1;
  JPH::Vec3 axis = JPH::Vec3(hx, hy, hz).Normalized();
  // A reference direction not parallel to the axis, so the normal is stable.
  JPH::Vec3 ref = (std::abs(axis.GetY()) < 0.99f) ? JPH::Vec3(0, 1, 0) : JPH::Vec3(1, 0, 0);
  JPH::Vec3 normal = axis.Cross(ref).Normalized();
  JPH::HingeConstraintSettings settings;
  settings.mSpace = JPH::EConstraintSpace::WorldSpace;
  settings.mPoint1 = settings.mPoint2 = JPH::RVec3(px, py, pz);
  settings.mHingeAxis1 = settings.mHingeAxis2 = axis;
  settings.mNormalAxis1 = settings.mNormalAxis2 = normal;
  add_constraint(world, settings.Create(*a, *b), ids[0], ids[1]);
  return 0;
}

// Links two bodies with a soft distance constraint held at rest_length by a
// spring (frequency in Hz, damping 0..1) - a springy tether that stretches
// under load and bobs back, unlike the rigid distance chain.
extern "C" int32_t goss_physics_constrain_spring(void* handle, uint32_t body_a, uint32_t body_b, float ax, float ay, float az, float bx, float by, float bz, float rest_length, float frequency, float damping) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || !allFinite({ax, ay, az, bx, by, bz, rest_length, frequency, damping})) return -1;
  const JPH::BodyID ids[2] = {JPH::BodyID(body_a), JPH::BodyID(body_b)};
  JPH::BodyLockMultiWrite lock(world->system.GetBodyLockInterface(), ids, 2);
  JPH::Body* a = lock.GetBody(0);
  JPH::Body* b = lock.GetBody(1);
  if (a == nullptr || b == nullptr) return -1;
  JPH::DistanceConstraintSettings settings;
  settings.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
  settings.mPoint1 = JPH::RVec3(ax, ay, az);
  settings.mPoint2 = JPH::RVec3(bx, by, bz);
  settings.mMinDistance = rest_length;
  settings.mMaxDistance = rest_length;
  settings.mLimitsSpringSettings = JPH::SpringSettings(JPH::ESpringMode::FrequencyAndDamping, frequency, damping);
  add_constraint(world, settings.Create(*a, *b), ids[0], ids[1]);
  return 0;
}

// Moves a kinematic body toward a pose over dt - the anchor's per-frame
// drive; chained bodies swing after it.
extern "C" void goss_physics_body_move(void* handle, uint32_t body, float px, float py, float pz, float dt_seconds) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || dt_seconds <= 0) return;
  world->system.GetBodyInterface().MoveKinematic(JPH::BodyID(body), JPH::RVec3(px, py, pz), JPH::Quat::sIdentity(), dt_seconds);
}

// Switches a body's motion type at runtime: a dynamic body grabbed into a
// kinematic drag, then released back to dynamic to fly off with the velocity
// the drag imparted.
extern "C" void goss_physics_body_set_motion(void* handle, uint32_t body, uint32_t motion) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return;
  auto& bi = world->system.GetBodyInterface();
  const JPH::BodyID id(body);
  {
    // A body created static has no MotionProperties; switching it to dynamic
    // or kinematic would deref null past the routed assert. Refuse instead.
    JPH::BodyLockRead lock(world->system.GetBodyLockInterface(), id);
    if (!lock.Succeeded()) return;
    if (motion != 0 && lock.GetBody().GetMotionPropertiesUnchecked() == nullptr) return;
  }
  const JPH::EMotionType motion_type = motion == 1   ? JPH::EMotionType::Dynamic
                                       : motion == 2 ? JPH::EMotionType::Kinematic
                                                     : JPH::EMotionType::Static;
  bi.SetMotionType(id, motion_type, JPH::EActivation::Activate);
  // Keep the object layer in step with the motion so broad-phase filtering
  // stays correct after the switch, not stale from creation.
  bi.SetObjectLayer(id, motion == 0 ? layer_static : layer_moving);
}

// Removes a body from the world and destroys it - an erased live collider.
extern "C" void goss_physics_body_remove(void* handle, uint32_t body) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return;
  auto& bi = world->system.GetBodyInterface();
  const JPH::BodyID id(body);
  // Drop constraints that reference this body before it is destroyed: a live
  // constraint would keep a dangling Body* dereferenced on the next step.
  for (size_t i = world->constraints.size(); i-- > 0;) {
    if (world->constraints[i].a == id || world->constraints[i].b == id) {
      world->system.RemoveConstraint(world->constraints[i].constraint);
      world->constraints.erase(world->constraints.begin() + i);
    }
  }
  for (size_t i = 0; i < world->tracked_bodies.size(); ++i) {
    if (world->tracked_bodies[i].id == id) {
      world->tracked_bodies.erase(world->tracked_bodies.begin() + i);
      break;
    }
  }
  bi.RemoveBody(id);
  bi.DestroyBody(id);
}

// Wakes a body so it re-evaluates its support - a body resting on a collider
// that was just erased must fall, not stay asleep in place.
extern "C" void goss_physics_body_wake(void* handle, uint32_t body) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return;
  world->system.GetBodyInterface().ActivateBody(JPH::BodyID(body));
}

// Fixed 60 Hz substeps accumulated from dt, the determinism contract.
extern "C" void goss_physics_step(void* handle, float dt_seconds) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return;
  world->accumulator += dt_seconds;
  const double step = 1.0 / 60.0;
  JPH::BodyInterface& bi = world->system.GetBodyInterface();
  while (world->accumulator >= step) {
    world->system.Update((float)step, 1, &world->temp, &world->jobs);
    world->accumulator -= step;
    world->total_substeps += 1;
    for (TrackedBody& tb : world->tracked_bodies) {
      JPH::RVec3 pos = bi.GetPosition(tb.id);
      JPH::Quat rot = bi.GetRotation(tb.id);
      JPH::Vec3 lv = bi.GetLinearVelocity(tb.id);
      JPH::Vec3 av = bi.GetAngularVelocity(tb.id);
      // Roll a body that blew up back to its last finite pose rather than let
      // the NaN spread; the world stays stable where one float path diverges.
      if (!poseIsFinite(pos, rot, lv, av)) {
        if (tb.reports++ < 3) {
          fprintf(stderr, "jolt guard: body %u non-finite at substep %d, last good pos (%.3f %.3f %.3f) planar=%d\n",
                  tb.id.GetIndexAndSequenceNumber(), world->total_substeps,
                  (double)tb.last_pos.GetX(), (double)tb.last_pos.GetY(), (double)tb.last_pos.GetZ(), tb.planar ? 1 : 0);
        }
        bi.SetPositionAndRotation(tb.id, tb.last_pos, tb.last_rot, JPH::EActivation::DontActivate);
        bi.SetLinearVelocity(tb.id, JPH::Vec3::sZero());
        bi.SetAngularVelocity(tb.id, JPH::Vec3::sZero());
        pos = tb.last_pos;
        rot = tb.last_rot;
      } else if (tb.planar) {
        // Hold the planar body in its plane: reset z and the out-of-plane
        // motion the step added, leaving x/y translation and z spin.
        pos = JPH::RVec3(pos.GetX(), pos.GetY(), tb.plane_z);
        bi.SetPosition(tb.id, pos, JPH::EActivation::DontActivate);
        bi.SetLinearVelocity(tb.id, JPH::Vec3(lv.GetX(), lv.GetY(), 0.0f));
        bi.SetAngularVelocity(tb.id, JPH::Vec3(0.0f, 0.0f, av.GetZ()));
      }
      tb.last_pos = pos;
      tb.last_rot = rot;
    }
  }
}

// Writes the body's column-major world transform into out[16].
extern "C" int32_t goss_physics_body_pose(void* handle, uint32_t body, float* out) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || out == nullptr) return -1;
  const JPH::BodyID id(body);
  if (id.IsInvalid()) return -1;
  const JPH::RMat44 transform = world->system.GetBodyInterface().GetWorldTransform(id);
  for (int column = 0; column < 4; column++) {
    const JPH::Vec4 v = transform.GetColumn4(column);
    out[column * 4 + 0] = v.GetX();
    out[column * 4 + 1] = v.GetY();
    out[column * 4 + 2] = v.GetZ();
    out[column * 4 + 3] = v.GetW();
  }
  return 0;
}

// Adds a cols x rows cloth grid spanning width x height metres at
// (px,py,pz), top row pinned. Returns the soft body id, or UINT32_MAX.
// Vertices are row-major (cols*rows) so the reader returns mesh order.
extern "C" uint32_t goss_physics_add_cloth(void* handle, uint32_t cols, uint32_t rows, float width, float height, float px, float py, float pz) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || cols < 2 || rows < 2 || !allFinite({width, height, px, py, pz})) return UINT32_MAX;
  JPH::Ref<JPH::SoftBodySharedSettings> shared = nothrowNew<JPH::SoftBodySharedSettings>();
  if (shared == nullptr) return UINT32_MAX;
  for (uint32_t y = 0; y < rows; y++) {
    for (uint32_t x = 0; x < cols; x++) {
      const float fx = width * ((float)x / (cols - 1) - 0.5f);
      const float fy = height * (float)y / (rows - 1);
      const float inv_mass = (y == rows - 1) ? 0.0f : 1.0f;
      shared->mVertices.push_back(JPH::SoftBodySharedSettings::Vertex(JPH::Float3(fx, fy, 0), JPH::Float3(0, 0, 0), inv_mass));
    }
  }
  for (uint32_t y = 0; y < rows - 1; y++) {
    for (uint32_t x = 0; x < cols - 1; x++) {
      const JPH::uint32 a = y * cols + x, b = y * cols + x + 1, c = (y + 1) * cols + x, d = (y + 1) * cols + x + 1;
      shared->AddFace(JPH::SoftBodySharedSettings::Face(a, c, b));
      shared->AddFace(JPH::SoftBodySharedSettings::Face(b, c, d));
    }
  }
  JPH::SoftBodySharedSettings::VertexAttributes attr(1.0e-4f, 1.0e-4f, 1.0e-4f);
  shared->CreateConstraints(&attr, 1);
  shared->Optimize();
  JPH::SoftBodyCreationSettings settings(shared, JPH::RVec3(px, py, pz), JPH::Quat::sIdentity(), layer_moving);
  const JPH::BodyID id = world->system.GetBodyInterface().CreateAndAddSoftBody(settings, JPH::EActivation::Activate);
  return id.IsInvalid() ? UINT32_MAX : id.GetIndexAndSequenceNumber();
}

// Adds a closed soft body from a mesh (three floats per vertex, three indices
// per face) with an internal pressure: a positive pressure inflates the volume
// (a balloon), zero leaves a limp shell. Reads back with cloth_read. Returns
// the body id, or UINT32_MAX.
extern "C" uint32_t goss_physics_add_softbody(void* handle, const float* verts, uint32_t vert_count, const uint32_t* faces, uint32_t face_count, float pressure, uint32_t pin_top, float px, float py, float pz) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || verts == nullptr || faces == nullptr || vert_count < 4 || face_count < 4) return UINT32_MAX;
  if (!allFinite({pressure, px, py, pz})) return UINT32_MAX;
  // A non-finite input vertex would seed a soft body born diverged; refuse it
  // rather than let the sim carry the NaN.
  for (uint32_t i = 0; i < vert_count * 3; ++i) if (!std::isfinite(verts[i])) return UINT32_MAX;
  // Pinning holds the top cap so a balloon hangs in place instead of falling.
  float min_y = verts[1], max_y = verts[1];
  for (uint32_t i = 0; i < vert_count; ++i) {
    min_y = std::min(min_y, verts[i * 3 + 1]);
    max_y = std::max(max_y, verts[i * 3 + 1]);
  }
  const float pin_below = max_y - 0.2f * (max_y - min_y);
  JPH::Ref<JPH::SoftBodySharedSettings> shared = nothrowNew<JPH::SoftBodySharedSettings>();
  if (shared == nullptr) return UINT32_MAX;
  for (uint32_t i = 0; i < vert_count; ++i) {
    const float vy = verts[i * 3 + 1];
    const float inv_mass = (pin_top != 0 && vy >= pin_below) ? 0.0f : 1.0f;
    shared->mVertices.push_back(JPH::SoftBodySharedSettings::Vertex(JPH::Float3(verts[i * 3], vy, verts[i * 3 + 2]), JPH::Float3(0, 0, 0), inv_mass));
  }
  for (uint32_t f = 0; f < face_count; ++f) {
    if (faces[f * 3] >= vert_count || faces[f * 3 + 1] >= vert_count || faces[f * 3 + 2] >= vert_count) return UINT32_MAX;
    shared->AddFace(JPH::SoftBodySharedSettings::Face(faces[f * 3], faces[f * 3 + 1], faces[f * 3 + 2]));
  }
  // A softer edge compliance lets the internal pressure inflate the shell.
  JPH::SoftBodySharedSettings::VertexAttributes attr(1.0e-2f, 1.0e-2f, 1.0e-2f);
  shared->CreateConstraints(&attr, 1);
  shared->Optimize();
  JPH::SoftBodyCreationSettings settings(shared, JPH::RVec3(px, py, pz), JPH::Quat::sIdentity(), layer_moving);
  settings.mPressure = pressure;
  const JPH::BodyID id = world->system.GetBodyInterface().CreateAndAddSoftBody(settings, JPH::EActivation::Activate);
  return id.IsInvalid() ? UINT32_MAX : id.GetIndexAndSequenceNumber();
}

// Reads the cloth's deformed world-space vertices into out (three
// floats per vertex, up to max_vertices). Returns the count.
extern "C" uint32_t goss_physics_cloth_read(void* handle, uint32_t body, float* out, uint32_t max_vertices) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || out == nullptr) return 0;
  const JPH::BodyID id(body);
  JPH::BodyLockRead lock(world->system.GetBodyLockInterface(), id);
  if (!lock.Succeeded()) return 0;
  const JPH::Body& b = lock.GetBody();
  if (!b.IsSoftBody()) return 0;
  const JPH::SoftBodyMotionProperties* mp = static_cast<const JPH::SoftBodyMotionProperties*>(b.GetMotionProperties());
  const JPH::RVec3 com = b.GetCenterOfMassPosition();
  const auto& verts = mp->GetVertices();
  const uint32_t count = (uint32_t)verts.size() < max_vertices ? (uint32_t)verts.size() : max_vertices;
  for (uint32_t i = 0; i < count; i++) {
    const JPH::RVec3 p = com + verts[i].mPosition;
    out[i * 3 + 0] = finiteOr0((float)p.GetX());
    out[i * 3 + 1] = finiteOr0((float)p.GetY());
    out[i * 3 + 2] = finiteOr0((float)p.GetZ());
  }
  return count;
}

// Adds a hanging clump of `strand_count` strands, each `verts` vertices
// long and `length` metres, rooted near the origin. Returns a hair id
// (index) for this world, or UINT32_MAX. Simulated on the CPU compute
// backend, deterministic.
extern "C" uint32_t goss_physics_add_hair(void* handle, uint32_t strand_count, uint32_t verts, float length) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || strand_count < 1 || verts < 2 || !std::isfinite(length)) return UINT32_MAX;
  if (!g_hair_registered) { JPH::RegisterHair(); g_hair_registered = true; }
  if (!world->hair_ready) {
    world->compute = JPH::StaticCast<JPH::ComputeSystemCPU>(JPH::CreateComputeSystemCPU().Get());
    if (world->compute == nullptr) return UINT32_MAX;
    JPH::HairRegisterShaders(world->compute);
    world->queue = world->compute->CreateComputeQueue().Get();
    world->hair_shaders.Init(world->compute);
    world->hair_ready = true;
  }
  JPH::Array<JPH::HairSettings::SVertex> sverts;
  JPH::Array<JPH::HairSettings::SStrand> sstrands;
  for (uint32_t s = 0; s < strand_count; s++) {
    const float sx = -0.1f + 0.2f * (float)s / (strand_count > 1 ? strand_count - 1 : 1);
    const uint32_t start = (uint32_t)sverts.size();
    for (uint32_t i = 0; i < verts; i++) {
      JPH::HairSettings::SVertex v;
      v.mPosition = JPH::Float3(sx, 0.5f - length * (float)i / (verts - 1), 0.0f);
      v.mInvMass = (i == 0) ? 0.0f : 1.0f;  // root pinned
      sverts.push_back(v);
    }
    sstrands.push_back(JPH::HairSettings::SStrand(start, start + verts, 0));
  }
  JPH::Ref<JPH::HairSettings> settings = nothrowNew<JPH::HairSettings>();
  if (settings == nullptr) return UINT32_MAX;
  JPH::HairSettings::Material m;
  m.mEnableLRA = false;
  m.mBendCompliance = 1e-8f;
  m.mStretchCompliance = 1e-10f;
  settings->mMaterials.push_back(m);
  settings->mSimulationBoundsPadding = JPH::Vec3::sReplicate(1.0f);
  settings->InitRenderAndSimulationStrands(sverts, sstrands);
  float max_dist_sq = 0.0f;
  settings->Init(max_dist_sq);
  settings->InitCompute(world->compute);
  JPH::Hair* hair = new (std::nothrow) JPH::Hair(settings, JPH::RVec3::sZero(), JPH::Quat::sIdentity(), layer_moving);
  if (hair == nullptr) return UINT32_MAX;
  hair->Init(world->compute);
  hair->Update(0.0f, JPH::Mat44::sIdentity(), nullptr, world->system, world->hair_shaders, world->compute, world->queue);
  hair->ReadBackGPUState(world->queue);
  const uint32_t id = (uint32_t)world->hairs.size();
  world->hairs.push_back({ settings, hair });
  return id;
}

// Releases one hair before the world goes: deletes the simulation object
// and drops the settings ref, leaving a tombstone slot so the other hair
// ids stay valid. Returns 1 on removal, 0 for an unknown or removed id.
extern "C" uint32_t goss_physics_remove_hair(void* handle, uint32_t hair_id) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || hair_id >= world->hairs.size()) return 0;
  HairInstance& instance = world->hairs[hair_id];
  if (instance.hair == nullptr) return 0;
  delete instance.hair;
  instance.hair = nullptr;
  instance.settings = nullptr;
  return 1;
}

// Moves the hair with the head (a translation extracted from the 4x4
// column-major head transform) and steps it; the free tips swing.
extern "C" void goss_physics_hair_update(void* handle, uint32_t hair_id, const float* head_transform, float dt_seconds) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || hair_id >= world->hairs.size() || dt_seconds <= 0) return;
  JPH::Hair* hair = world->hairs[hair_id].hair;
  if (hair == nullptr) return;
  if (head_transform != nullptr) {
    hair->SetPosition(JPH::RVec3(head_transform[12], head_transform[13], head_transform[14]));
  }
  hair->Update(dt_seconds, JPH::Mat44::sIdentity(), nullptr, world->system, world->hair_shaders, world->compute, world->queue);
  hair->ReadBackGPUState(world->queue);
}

// Reads simulated strand vertex positions (three floats each) into out.
extern "C" uint32_t goss_physics_hair_read(void* handle, uint32_t hair_id, float* out, uint32_t max_vertices) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || out == nullptr || hair_id >= world->hairs.size()) return 0;
  const JPH::Hair* hair = world->hairs[hair_id].hair;
  if (hair == nullptr) return 0;
  const JPH::Float3* positions = hair->GetPositions();
  if (positions == nullptr) return 0;
  const uint32_t count = world->hairs[hair_id].settings->GetNumVerticesPadded() < max_vertices ? world->hairs[hair_id].settings->GetNumVerticesPadded() : max_vertices;
  for (uint32_t i = 0; i < count; i++) {
    out[i * 3 + 0] = finiteOr0(positions[i].x);
    out[i * 3 + 1] = finiteOr0(positions[i].y);
    out[i * 3 + 2] = finiteOr0(positions[i].z);
  }
  return count;
}
