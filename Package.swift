// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "matcha",
  products: [
    .library(name: "Matcha", targets: ["Matcha"]),
    .executable(name: "matcha", targets: ["MatchaCLI"]),
    .executable(name: "MatchaBenchmarks", targets: ["MatchaBenchmarks"]),
  ],
  targets: [
    .target(
      name: "Matcha",
      path: "Sources/Matcha",
      exclude: ["Matcha.docc"]
    ),
    .executableTarget(
      name: "MatchaCLI",
      dependencies: ["Matcha"],
      path: "Sources/MatchaCLI"
    ),
    .executableTarget(
      name: "MatchaBenchmarks",
      dependencies: ["Matcha"],
      path: "Sources/MatchaBenchmarks"
    ),
    .testTarget(
      name: "MatchaTests",
      dependencies: ["Matcha"],
      path: "Tests/MatchaTests",
      exclude: ["Fixtures"]
    ),
  ]
)
