import Foundation

// The asset-free post lenses the filter picker swaps between. Each one is
// a single pass over the "camera" input, activated straight from the inline
// manifest below so the demo needs no bundled lens folder for them. None
// rides the bundled reference lens instead, so it carries no inline form.
enum PostFilter: Int, CaseIterable {
    case none
    case blur
    case grade
    case bloom

    var title: String {
        switch self {
        case .none: return "None"
        case .blur: return "Blur"
        case .grade: return "Grade"
        case .bloom: return "Bloom"
        }
    }

    var manifestJSON: String? {
        switch self {
        case .none:
            return nil
        case .blur:
            return Self.manifest(id: "goss.demo.blur", name: "Blur",
                                 node: "{\"id\":\"blur\",\"type\":\"blur.pass\",\"inputs\":{\"frame\":\"camera\"},\"params\":{}}")
        case .grade:
            return Self.manifest(id: "goss.demo.grade", name: "Grade",
                                 node: "{\"id\":\"grade\",\"type\":\"grade.pass\",\"inputs\":{\"frame\":\"camera\"},\"params\":{},\"grade\":{\"exposure\":0.1,\"contrast\":1.15,\"saturation\":1.2,\"temperature\":0.05}}")
        case .bloom:
            return Self.manifest(id: "goss.demo.bloom", name: "Bloom",
                                 node: "{\"id\":\"glow\",\"type\":\"bloom.pass\",\"inputs\":{\"frame\":\"camera\"},\"params\":{},\"bloom\":{\"threshold\":0.6,\"intensity\":0.8}}")
        }
    }

    var manifestData: Data? { manifestJSON?.data(using: .utf8) }

    private static func manifest(id: String, name: String, node: String) -> String {
        "{\"glf\":\"1.0\",\"id\":\"\(id)\",\"version\":\"1.0.0\",\"display_name\":\"\(name)\",\"engine_compat\":\">=0.5\",\"capabilities\":[],\"parameters\":[],\"nodes\":[\(node)],\"triggers\":[]}"
    }
}
