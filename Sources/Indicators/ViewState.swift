import SwiftUI

/// Minimal observable box used instead of `@State`.
///
/// The macOS SDK that ships with Command Line Tools lacks the `SwiftUIMacros` plugin that `@State`
/// expands through, so this project keeps local view state in `@StateObject` boxes to stay buildable
/// with `swift build` alone (no Xcode required).
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
