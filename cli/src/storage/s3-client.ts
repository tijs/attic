import {
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";

export interface S3Object {
  key: string;
  size: number;
  lastModified: Date | null;
}

export interface S3ObjectMeta {
  contentLength: number;
  contentType: string | null;
  etag: string | null;
}

export interface S3Provider {
  putObject(
    key: string,
    body: Uint8Array,
    contentType?: string,
  ): Promise<void>;
  getObject(key: string): Promise<Uint8Array>;
  headObject(key: string): Promise<S3ObjectMeta | null>;
  listObjects(prefix: string): AsyncIterable<S3Object>;
}

export interface S3ConnectionConfig {
  endpoint: string;
  region: string;
  pathStyle: boolean;
}

/** Base timeout for S3 requests (2 minutes).
 *  For putObject, this is extended based on body size to allow large uploads. */
const BASE_TIMEOUT_MS = 120_000;

/** Minimum assumed upload speed for timeout calculation (~500 KB/s). */
const MIN_BYTES_PER_MS = 500;

export function createS3Provider(
  credentials: { accessKeyId: string; secretAccessKey: string },
  bucket: string,
  connection: S3ConnectionConfig,
): S3Provider {
  const client = new S3Client({
    endpoint: connection.endpoint,
    region: connection.region,
    credentials: {
      accessKeyId: credentials.accessKeyId,
      secretAccessKey: credentials.secretAccessKey,
    },
    forcePathStyle: connection.pathStyle,
  });

  return {
    async putObject(
      key: string,
      body: Uint8Array,
      contentType?: string,
    ): Promise<void> {
      // Scale timeout with body size: base + time at ~500KB/s
      const timeoutMs = BASE_TIMEOUT_MS +
        Math.ceil(body.byteLength / MIN_BYTES_PER_MS);
      await client.send(
        new PutObjectCommand({
          Bucket: bucket,
          Key: key,
          Body: body,
          ContentType: contentType,
        }),
        { abortSignal: AbortSignal.timeout(timeoutMs) },
      );
    },

    async getObject(key: string): Promise<Uint8Array> {
      const result = await client.send(
        new GetObjectCommand({ Bucket: bucket, Key: key }),
        { abortSignal: AbortSignal.timeout(BASE_TIMEOUT_MS) },
      );
      const stream = result.Body;
      if (!stream) throw new Error(`Empty response for ${key}`);
      return new Uint8Array(await stream.transformToByteArray());
    },

    async headObject(key: string): Promise<S3ObjectMeta | null> {
      try {
        const result = await client.send(
          new HeadObjectCommand({ Bucket: bucket, Key: key }),
          { abortSignal: AbortSignal.timeout(BASE_TIMEOUT_MS) },
        );
        return {
          contentLength: result.ContentLength ?? 0,
          contentType: result.ContentType ?? null,
          etag: result.ETag ?? null,
        };
      } catch (error: unknown) {
        if (error instanceof Error && error.name === "NotFound") {
          return null;
        }
        throw error;
      }
    },

    async *listObjects(prefix: string): AsyncIterable<S3Object> {
      let continuationToken: string | undefined;
      do {
        const result = await client.send(
          new ListObjectsV2Command({
            Bucket: bucket,
            Prefix: prefix,
            ContinuationToken: continuationToken,
          }),
          { abortSignal: AbortSignal.timeout(BASE_TIMEOUT_MS) },
        );
        for (const obj of result.Contents ?? []) {
          if (obj.Key) {
            yield {
              key: obj.Key,
              size: obj.Size ?? 0,
              lastModified: obj.LastModified ?? null,
            };
          }
        }
        continuationToken = result.NextContinuationToken;
      } while (continuationToken);
    },
  };
}
