---
title: URL.appendingPathComponent double-encodes percent-encoded keys; use URLComponents.percentEncodedPath
date: 2026-05-02
category: docs/solutions/runtime-errors
module: AtticCore
problem_type: runtime_error
component: service_object
symptoms:
  - "S3 returns 404 / SignatureDoesNotMatch for keys that contain percent-encoded characters"
  - "Presigned URLs visibly contain `%25` where `%` should be (e.g., `%252F` instead of `%2F`)"
  - "AWS SigV4 canonical URI mismatches the actual request path"
root_cause: wrong_api
resolution_type: code_fix
severity: high
related_components:
  - tooling
tags:
  - s3
  - url-encoding
  - sigv4
  - foundation
  - urlsession
---

# URL.appendingPathComponent double-encodes percent-encoded keys; use URLComponents.percentEncodedPath

## Problem
`URL.appendingPathComponent(_:)` re-encodes its input by escaping any character that is not valid in a URL path. Because `%` itself is not a valid path character (it must always introduce a percent-encoded triplet), the API encodes `%` to `%25` — silently corrupting any key that already contains percent-encoded characters. AWS SigV4 then signs one canonical URI while the request is sent with another, and S3 rejects the request.

## Symptoms
- A key like `metadata/assets/<id>%3A001%3A<rest>.json` reaches S3 as `metadata/assets/<id>%253A001%253A<rest>.json`
- Presigned URLs returned to the browser show `%25` doubled-up where the original encoding lived
- SigV4 signature validation fails because the canonical URI computed by the signer does not match what the URL contains
- Behavior is silent: no client-side error, just an opaque 403/404 from S3

## What Didn't Work
- **Trusting the type signature.** `appendingPathComponent` looks like the obvious "concatenate path segment" API and Foundation gives no warning that already-encoded inputs are corrupted.
- **Eyeballing the URL once and assuming it's right.** The first `print(url)` showed `%2F` as expected — but that was because the test key didn't contain `%` yet. The corruption only surfaces when the input already carries percent-encoding.
- **Pre-decoding then re-appending.** Decoding the key, calling `appendingPathComponent`, and accepting Foundation's re-encoding seems tidy but loses control over which characters get encoded — the unreserved set Foundation uses is broader than the one you actually want for canonical URI signing.

## Solution
Build the path with `URLComponents.percentEncodedPath`, which does not re-encode its input. The pre-encoded key flows through to AWS SigV4 unchanged.

```swift
// Sources/AtticCore/URLSessionS3Client.swift

private func makePathStyleURL(key: String) throws -> URL {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
        throw S3ClientError.unexpectedResponse("Invalid endpoint URL: \(endpoint)")
    }
    let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var fullPath = basePath.isEmpty ? "/\(bucket)" : "/\(basePath)/\(bucket)"
    if !key.isEmpty {
        fullPath += "/" + key
    }
    components.percentEncodedPath = fullPath
    guard let url = components.url else {
        throw S3ClientError.unexpectedResponse("Invalid path-style URL for key: \(key)")
    }
    return url
}

private func makeVirtualHostedURL(key: String) throws -> URL {
    let host = endpoint.host ?? ""
    let scheme = endpoint.scheme ?? "https"
    let port = endpoint.port.map { ":\($0)" } ?? ""
    let bucketHost = "\(scheme)://\(bucket).\(host)\(port)"
    guard var components = URLComponents(string: bucketHost) else {
        throw S3ClientError.unexpectedResponse("Invalid virtual-hosted URL: \(bucketHost)")
    }
    if !key.isEmpty {
        components.percentEncodedPath = "/" + key
    }
    guard let url = components.url else {
        throw S3ClientError.unexpectedResponse("Invalid virtual-hosted URL for key: \(key)")
    }
    return url
}
```

## Why This Works
- `URLComponents.percentEncodedPath` is the explicit "I have already encoded this" entry point. It writes the bytes through verbatim and does not apply the path-allowed character set.
- The contract between key generation (which percent-encodes per RFC 3986 unreserved) and URL construction (which preserves the encoding) is now a single boundary, not two layers fighting each other.
- AWS SigV4 sees the same canonical URI bytes that go on the wire, so signatures match.

## Prevention
- **Default to `URLComponents` for any URL whose path is built from variable input.** Reach for `URL.appendingPathComponent` only when the inputs are guaranteed to be unencoded ASCII path segments — which is rare in practice.
- **Verify URL behavior empirically when in doubt.** A 10-line scratch script settles the question faster than reading docs:
  ```swift
  let u = URL(string: "https://h.x")!.appendingPathComponent("a%2Fb")
  print(u.path)  // /a%252Fb — confirmation of the double-encoding
  let c = URLComponents(string: "https://h.x")!
  var c2 = c; c2.percentEncodedPath = "/a%2Fb"
  print(c2.url!.path)  // /a/b after Foundation decodes for display, but the on-wire bytes are /a%2Fb
  ```
- **Cover SigV4 paths with a regression test that builds an encoded key and round-trips through the client.** See `Tests/AtticCoreTests/CloudIdentifierShapeTests.swift` — `presignedURLPreservesPercentEncoding` asserts no `%25` shows up in the absolute URL string.
- **Pair the encoder and the URL builder in the same module** so future changes are visible together. Splitting them across files invites a future change to one side that breaks the contract.

## Related Issues
- `docs/migration-cloud-identity.md` — explains why cloud IDs need encoding in the first place
- Commit: `336fac9` (beta.10 fix)
- Tests: `Tests/AtticCoreTests/CloudIdentifierShapeTests.swift` — `presignedURLPreservesPercentEncoding`, `presignedURLVirtualHostedPath`
- See also: `docs/solutions/runtime-errors/percent-encode-external-identifiers-in-s3-keys-2026-05-02.md` (producer side — generating the encoded keys)
