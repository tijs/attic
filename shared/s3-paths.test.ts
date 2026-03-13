import { assertEquals, assertThrows } from "@std/assert";
import {
  extensionFromUtiOrFilename,
  metadataKey,
  originalKey,
} from "./s3-paths.ts";

Deno.test("originalKey generates correct path", () => {
  const date = new Date("2024-01-15T12:00:00Z");
  const key = originalKey("abc-uuid", date, "heic");
  assertEquals(key, "originals/2024/01/abc-uuid.heic");
});

Deno.test("originalKey handles null date", () => {
  const key = originalKey("abc-uuid", null, "jpg");
  assertEquals(key, "originals/unknown/00/abc-uuid.jpg");
});

Deno.test("originalKey strips leading dot from extension", () => {
  const date = new Date("2024-03-01T00:00:00Z");
  const key = originalKey("x", date, ".HEIC");
  assertEquals(key, "originals/2024/03/x.heic");
});

Deno.test("originalKey rejects unsafe uuid", () => {
  const date = new Date("2024-01-15T12:00:00Z");
  assertThrows(
    () => originalKey("../../../etc", date, "heic"),
    Error,
    "Unsafe UUID",
  );
  assertThrows(
    () => originalKey("uuid/with/slashes", date, "heic"),
    Error,
    "Unsafe UUID",
  );
});

Deno.test("originalKey rejects unsafe extension", () => {
  const date = new Date("2024-01-15T12:00:00Z");
  assertThrows(
    () => originalKey("abc", date, "h/e"),
    Error,
    "Unsafe extension",
  );
});

Deno.test("metadataKey generates correct path", () => {
  assertEquals(metadataKey("abc-uuid"), "metadata/assets/abc-uuid.json");
});

Deno.test("metadataKey rejects unsafe uuid", () => {
  assertThrows(
    () => metadataKey("../escape"),
    Error,
    "Unsafe UUID",
  );
});

Deno.test("extensionFromUtiOrFilename maps known UTIs", () => {
  assertEquals(
    extensionFromUtiOrFilename("public.heic", "IMG_001.HEIC"),
    "heic",
  );
  assertEquals(
    extensionFromUtiOrFilename("public.jpeg", "IMG_002.JPG"),
    "jpg",
  );
  assertEquals(
    extensionFromUtiOrFilename("com.apple.quicktime-movie", "IMG_003.MOV"),
    "mov",
  );
});

Deno.test("extensionFromUtiOrFilename falls back to filename", () => {
  assertEquals(
    extensionFromUtiOrFilename("some.unknown.uti", "photo.webp"),
    "webp",
  );
});

Deno.test("extensionFromUtiOrFilename returns bin as last resort", () => {
  assertEquals(extensionFromUtiOrFilename(null, "noext"), "bin");
});
