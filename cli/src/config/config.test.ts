import { assertEquals, assertThrows } from "@std/assert";
import { loadConfig, validateConfig, writeConfig } from "./config.ts";
import { join } from "@std/path/join";

Deno.test("validateConfig accepts valid config with all fields", () => {
  const config = validateConfig({
    endpoint: "https://s3.fr-par.scw.cloud",
    region: "fr-par",
    bucket: "my-photo-backup",
    pathStyle: false,
    keychain: {
      accessKeyService: "custom-access",
      secretKeyService: "custom-secret",
    },
  });

  assertEquals(config.endpoint, "https://s3.fr-par.scw.cloud");
  assertEquals(config.region, "fr-par");
  assertEquals(config.bucket, "my-photo-backup");
  assertEquals(config.pathStyle, false);
  assertEquals(config.keychain.accessKeyService, "custom-access");
  assertEquals(config.keychain.secretKeyService, "custom-secret");
});

Deno.test("validateConfig applies defaults for optional fields", () => {
  const config = validateConfig({
    endpoint: "https://s3.fr-par.scw.cloud",
    region: "fr-par",
    bucket: "my-photo-backup",
  });

  assertEquals(config.pathStyle, true);
  assertEquals(config.keychain.accessKeyService, "attic-s3-access-key");
  assertEquals(config.keychain.secretKeyService, "attic-s3-secret-key");
});

Deno.test("validateConfig rejects missing endpoint", () => {
  assertThrows(
    () => validateConfig({ region: "fr-par", bucket: "b" }),
    Error,
    '"endpoint" is required',
  );
});

Deno.test("validateConfig rejects non-https endpoint", () => {
  assertThrows(
    () =>
      validateConfig({
        endpoint: "http://s3.example.com",
        region: "us-east-1",
        bucket: "bbb",
      }),
    Error,
    "must start with https://",
  );
});

Deno.test("validateConfig rejects missing region", () => {
  assertThrows(
    () => validateConfig({ endpoint: "https://s3.example.com", bucket: "bbb" }),
    Error,
    '"region" is required',
  );
});

Deno.test("validateConfig rejects missing bucket", () => {
  assertThrows(
    () =>
      validateConfig({
        endpoint: "https://s3.example.com",
        region: "us-east-1",
      }),
    Error,
    '"bucket" is required',
  );
});

Deno.test("validateConfig rejects invalid bucket name", () => {
  assertThrows(
    () =>
      validateConfig({
        endpoint: "https://s3.example.com",
        region: "us-east-1",
        bucket: "A",
      }),
    Error,
    "is invalid",
  );
});

Deno.test("validateConfig rejects non-object input", () => {
  assertThrows(
    () => validateConfig("not an object"),
    Error,
    "must be a JSON object",
  );
  assertThrows(
    () => validateConfig(null),
    Error,
    "must be a JSON object",
  );
});

Deno.test("writeConfig and loadConfig round-trip", () => {
  const dir = Deno.makeTempDirSync();
  const config = {
    endpoint: "https://s3.fr-par.scw.cloud",
    region: "fr-par",
    bucket: "test-bucket",
    pathStyle: true,
    keychain: {
      accessKeyService: "attic-s3-access-key",
      secretKeyService: "attic-s3-secret-key",
    },
  };

  writeConfig(config, dir);

  // Verify file exists
  const text = Deno.readTextFileSync(join(dir, "config.json"));
  const parsed = JSON.parse(text);
  assertEquals(parsed.endpoint, "https://s3.fr-par.scw.cloud");

  // Round-trip through loadConfig
  const loaded = loadConfig(dir);
  assertEquals(loaded, config);
});

Deno.test("loadConfig returns null when file does not exist", () => {
  const dir = Deno.makeTempDirSync();
  const result = loadConfig(dir);
  assertEquals(result, null);
});
