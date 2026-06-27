package protocol DependencyClient: Sendable {
    static var liveValue: Self { get }
    static var testValue: Self { get }
}

package func testDependency<D: DependencyClient>(
    of type: D.Type,
    injection: (inout D) -> Void = { _ in }
) -> D {
    var dependency = type.testValue
    injection(&dependency)
    return dependency
}
