/// Owned by one loaded language inside the engine actor. Sampler counts select
/// three immutable graphs; they do not each need their own MLModel instance.
struct PocketFlowModels<Model> {
    private var models: [String: Model] = [:]

    mutating func model(steps: Int, load: (String) throws -> Model) rethrows -> Model {
        let graph = steps == 4 || steps == 8 ? "flow\(steps)" : "flowstep"
        if let model = models[graph] { return model }
        let model = try load(graph)
        models[graph] = model
        return model
    }
}
