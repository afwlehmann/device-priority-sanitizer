import Foundation

// Entry point for the unit-test binary (top-level code requires this file to
// be named main.swift for swiftc). The test cases live in UnitTests.swift.

runUnitTests()

if unitTestFailures.isEmpty {
    print("unit tests: all passed")
    exit(0)
}
print("unit tests: \(unitTestFailures.count) failed")
exit(1)
