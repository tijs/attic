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
    body: Uint8Array | ReadableStream<Uint8Array>,
    contentType?: string,
  ): Promise<void>;
  getObject(key: string): Promise<Uint8Array>;
  headObject(key: string): Promise<S3ObjectMeta | null>;
  listObjects(prefix: string): AsyncIterable<S3Object>;
}

export interface ScalewayCredentials {
  accessKeyId: string;
  secretAccessKey: string;
}

/** Read Scaleway S3 credentials from macOS Keychain. */
export async function loadKeychainCredentials(): Promise<ScalewayCredentials> {
  const accessKeyId = await keychainGet("attic-s3-access-key");
  const secretAccessKey = await keychainGet("attic-s3-secret-key");
  return { accessKeyId, secretAccessKey };
}

async function keychainGet(service: string): Promise<string> {
  const cmd = new Deno.Command("security", {
    args: [
      "find-generic-password",
      "-s",
      service,
      "-w",
    ],
    stdout: "piped",
    stderr: "piped",
  });
  const { code, stdout, stderr } = await cmd.output();
  if (code !== 0) {
    const err = new TextDecoder().decode(stderr);
    throw new Error(
      `Failed to read keychain item "${service}": ${err.trim()}. ` +
        `Store it with: security add-generic-password -s ${service} -a attic -w "<value>"`,
    );
  }
  return new TextDecoder().decode(stdout).trim();
}

const SCALEWAY_ENDPOINT = "https://s3.fr-par.scw.cloud";
const SCALEWAY_REGION = "fr-par";

export function createS3Provider(
  credentials: ScalewayCredentials,
  bucket: string,
): S3Provider {
  const client = new S3Client({
    endpoint: SCALEWAY_ENDPOINT,
    region: SCALEWAY_REGION,
    credentials: {
      accessKeyId: credentials.accessKeyId,
      secretAccessKey: credentials.secretAccessKey,
    },
    forcePathStyle: true,
  });

  return {
    async putObject(
      key: string,
      body: Uint8Array | ReadableStream<Uint8Array>,
      contentType?: string,
    ): Promise<void> {
      await client.send(
        new PutObjectCommand({
          Bucket: bucket,
          Key: key,
          Body: body,
          ContentType: contentType,
        }),
      );
    },

    async getObject(key: string): Promise<Uint8Array> {
      const result = await client.send(
        new GetObjectCommand({ Bucket: bucket, Key: key }),
      );
      const stream = result.Body;
      if (!stream) throw new Error(`Empty response for ${key}`);
      return new Uint8Array(await stream.transformToByteArray());
    },

    async headObject(key: string): Promise<S3ObjectMeta | null> {
      try {
        const result = await client.send(
          new HeadObjectCommand({ Bucket: bucket, Key: key }),
        );
        return {
          contentLength: result.ContentLength ?? 0,
          contentType: result.ContentType ?? null,
          etag: result.ETag ?? null,
        };
      } catch (error: unknown) {
        if (
          error instanceof Error && "name" in error &&
          error.name === "NotFound"
        ) {
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
