import com.gosslens.*

// The engine refuses a caller from another ABI major before anything is built.
val engine = GossEngine.create(GossEngineConfig(texturePoolCapacity = 8u))
val session = GossSession.create(engine, GossSessionConfig(frameBudgetUs = 8_000u))

session.activateLens(manifestJson)

session.submitFrame(desc, planes)
val record = session.perceptionJson()
