@testable import AtticCore
import Foundation
import Testing

struct S3XMLParsingTests {
    // MARK: - ListObjectsV2

    @Test func parsesListObjectsV2Response() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>my-bucket</Name>
          <Prefix>originals/</Prefix>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>originals/2024/01/abc.heic</Key>
            <Size>1234567</Size>
          </Contents>
          <Contents>
            <Key>originals/2024/02/def.jpg</Key>
            <Size>89012</Size>
          </Contents>
        </ListBucketResult>
        """
        let result = parseListObjectsV2(data: Data(xml.utf8))

        #expect(result.objects.count == 2)
        #expect(result.objects[0].key == "originals/2024/01/abc.heic")
        #expect(result.objects[0].size == 1_234_567)
        #expect(result.objects[1].key == "originals/2024/02/def.jpg")
        #expect(result.objects[1].size == 89012)
        #expect(result.isTruncated == false)
        #expect(result.nextContinuationToken == nil)
    }

    @Test func parsesTruncatedResponseWithContinuationToken() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>abc123token</NextContinuationToken>
          <Contents>
            <Key>file1.txt</Key>
            <Size>100</Size>
          </Contents>
        </ListBucketResult>
        """
        let result = parseListObjectsV2(data: Data(xml.utf8))

        #expect(result.objects.count == 1)
        #expect(result.isTruncated == true)
        #expect(result.nextContinuationToken == "abc123token")
    }

    @Test func parsesEmptyListResponse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <IsTruncated>false</IsTruncated>
        </ListBucketResult>
        """
        let result = parseListObjectsV2(data: Data(xml.utf8))

        #expect(result.objects.isEmpty)
        #expect(result.isTruncated == false)
    }

    @Test func skipsContentsWithEmptyKey() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents>
            <Key></Key>
            <Size>100</Size>
          </Contents>
          <Contents>
            <Key>valid.txt</Key>
            <Size>200</Size>
          </Contents>
        </ListBucketResult>
        """
        let result = parseListObjectsV2(data: Data(xml.utf8))

        #expect(result.objects.count == 1)
        #expect(result.objects[0].key == "valid.txt")
    }

    // MARK: - S3 Error Parsing

    @Test func parsesS3ErrorResponse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error>
          <Code>NoSuchKey</Code>
          <Message>The specified key does not exist.</Message>
          <Key>missing-file.txt</Key>
          <RequestId>abc123</RequestId>
        </Error>
        """
        let error = parseS3Error(data: Data(xml.utf8))

        #expect(error != nil)
        #expect(error?.code == "NoSuchKey")
        #expect(error?.message == "The specified key does not exist.")
    }

    @Test func parsesAccessDeniedError() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error>
          <Code>AccessDenied</Code>
          <Message>Access Denied</Message>
        </Error>
        """
        let error = parseS3Error(data: Data(xml.utf8))

        #expect(error?.code == "AccessDenied")
        #expect(error?.message == "Access Denied")
    }

    @Test func returnsNilForNonErrorXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <SomethingElse>
          <Value>not an error</Value>
        </SomethingElse>
        """
        let error = parseS3Error(data: Data(xml.utf8))

        #expect(error == nil)
    }

    @Test func returnsNilForEmptyData() {
        let error = parseS3Error(data: Data())
        #expect(error == nil)
    }
}
