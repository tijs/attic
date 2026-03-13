import { assertEquals } from "@std/assert";
import { createMockS3Provider } from "./s3-client.mock.ts";

Deno.test("mock S3: put and get round-trip", async () => {
  const s3 = createMockS3Provider();
  const data = new TextEncoder().encode("hello");
  await s3.putObject("test/file.txt", data, "text/plain");

  const retrieved = await s3.getObject("test/file.txt");
  assertEquals(new TextDecoder().decode(retrieved), "hello");
});

Deno.test("mock S3: headObject returns null for missing", async () => {
  const s3 = createMockS3Provider();
  const result = await s3.headObject("nonexistent");
  assertEquals(result, null);
});

Deno.test("mock S3: headObject returns metadata for existing", async () => {
  const s3 = createMockS3Provider();
  await s3.putObject("key", new Uint8Array(42));
  const head = await s3.headObject("key");
  assertEquals(head?.contentLength, 42);
});

Deno.test("mock S3: listObjects filters by prefix", async () => {
  const s3 = createMockS3Provider();
  await s3.putObject("originals/2024/01/a.heic", new Uint8Array(1));
  await s3.putObject("originals/2024/02/b.heic", new Uint8Array(2));
  await s3.putObject("metadata/c.json", new Uint8Array(3));

  const keys: string[] = [];
  for await (const obj of s3.listObjects("originals/")) {
    keys.push(obj.key);
  }
  assertEquals(keys.length, 2);
});
