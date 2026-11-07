import Gosslens

// The engine refuses a caller from another ABI major before anything is built.
let engine = try GossEngine.create(config: GossEngineConfig(texturePoolCapacity: 8))
let session = try GossSession.create(engine: engine,
                                     config: GossSessionConfig(frameBudgetUs: 8_000))

_ = try session.activateLens(manifestJson: manifest)

try session.submitFrame(desc: desc, planes: planes)
let record = try session.perceptionJson()
