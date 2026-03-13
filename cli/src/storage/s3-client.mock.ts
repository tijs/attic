import type { S3Object, S3ObjectMeta, S3Provider } from "./s3-client.ts";

/** In-memory mock S3 provider for testing. */
export function createMockS3Provider(): S3Provider & {
  objects: Map<string, { body: Uint8Array; contentType?: string }>;
} {
  const objects = new Map<
    string,
    { body: Uint8Array; contentType?: string }
  >();

  return {
    objects,

    putObject(
      key: string,
      body: Uint8Array,
      contentType?: string,
    ): Promise<void> {
      objects.set(key, { body, contentType });
      return Promise.resolve();
    },

    getObject(key: string): Promise<Uint8Array> {
      const obj = objects.get(key);
      if (!obj) throw new Error(`Object not found: ${key}`);
      return Promise.resolve(obj.body);
    },

    headObject(key: string): Promise<S3ObjectMeta | null> {
      const obj = objects.get(key);
      if (!obj) return Promise.resolve(null);
      return Promise.resolve({
        contentLength: obj.body.length,
        contentType: obj.contentType ?? null,
        etag: null,
      });
    },

    async *listObjects(prefix: string): AsyncIterable<S3Object> {
      for (const [key, obj] of objects) {
        if (key.startsWith(prefix)) {
          yield { key, size: obj.body.length, lastModified: null };
        }
      }
    },
  };
}
