import Foundation

public actor DiscordRateLimiter {
  public static let shared = DiscordRateLimiter()

  private var routeBuckets: [String: String] = [:]
  private var blockedUntil: [String: Date] = [:]
  private var globalBlockedUntil: Date?
  private var nextRequestAt: Date?
  private var nextMutationAt: Date?

  public init() {}

  func waitBeforeRequest(routeKey: String, isMutation: Bool) async throws {
    while true {
      let now = Date()
      let bucketKey = routeBuckets[routeKey].map { "bucket:\($0)" }
      let deadlines = [
        globalBlockedUntil,
        blockedUntil["route:\(routeKey)"],
        bucketKey.flatMap { blockedUntil[$0] },
        nextRequestAt,
        isMutation ? nextMutationAt : nil,
      ].compactMap { $0 }
      guard let deadline = deadlines.max(), deadline > now else {
        nextRequestAt = now.addingTimeInterval(0.35)
        if isMutation {
          nextMutationAt = now.addingTimeInterval(1.5)
        }
        return
      }
      try await Task.sleep(for: .seconds(deadline.timeIntervalSince(now)))
    }
  }

  func observe(
    routeKey: String,
    response: HTTPURLResponse,
    retryAfter: Double?,
    globallyLimited: Bool
  ) {
    let now = Date()
    let bucket = response.value(forHTTPHeaderField: "X-RateLimit-Bucket")
    if let bucket {
      routeBuckets[routeKey] = bucket
    }

    if response.statusCode == 429, let retryAfter {
      let deadline = now.addingTimeInterval(max(retryAfter, 0.1))
      if globallyLimited {
        globalBlockedUntil = max(globalBlockedUntil ?? deadline, deadline)
      } else {
        block(routeKey: routeKey, bucket: bucket, until: deadline)
      }
      return
    }

    let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
      .flatMap(Int.init)
    let resetAfter = response.value(forHTTPHeaderField: "X-RateLimit-Reset-After")
      .flatMap(Double.init)
    if remaining == 0, let resetAfter, resetAfter > 0 {
      block(
        routeKey: routeKey,
        bucket: bucket,
        until: now.addingTimeInterval(resetAfter)
      )
    }
  }

  private func block(routeKey: String, bucket: String?, until deadline: Date) {
    let routeKey = "route:\(routeKey)"
    blockedUntil[routeKey] = max(blockedUntil[routeKey] ?? deadline, deadline)
    if let bucket {
      let bucketKey = "bucket:\(bucket)"
      blockedUntil[bucketKey] = max(blockedUntil[bucketKey] ?? deadline, deadline)
    }
  }
}
