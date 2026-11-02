// Linux stand-in for os.Logger: the same call shape, privacy annotations included; prints nothing.
public enum OSLogPrivacy { case `public`, `private` }

public struct OSLogMessage: ExpressibleByStringInterpolation {
  public struct StringInterpolation: StringInterpolationProtocol {
    public init(literalCapacity: Int, interpolationCount: Int) {}
    public mutating func appendLiteral(_ literal: String) {}
    public mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: OSLogPrivacy = .private) {}
  }
  public init(stringLiteral value: String) {}
  public init(stringInterpolation: StringInterpolation) {}
}

public struct Logger {
  public init(subsystem: String, category: String) {}
  public func info(_ message: OSLogMessage) {}
}
