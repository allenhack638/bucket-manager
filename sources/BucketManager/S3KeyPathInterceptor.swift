import AWSS3
import ClientRuntime
import Smithy
import SmithyHTTPAPI

/// The SDK builds endpoint paths with `URL.appendingPathComponent`, which drops
/// a trailing slash. S3 uses that slash to distinguish a folder marker from a
/// zero-byte object, so a `PutObject` for "new/" would otherwise create "new".
/// Restore it before the request is signed.
struct S3KeyPathInterceptorProvider: InterceptorProvider {
    func create<
        InputType,
        OutputType,
        RequestType: RequestMessage,
        ResponseType: ResponseMessage
    >() -> any Interceptor<InputType, OutputType, RequestType, ResponseType> {
        S3KeyPathInterceptor<InputType, OutputType, RequestType, ResponseType>()
    }
}

struct S3KeyPathInterceptor<
    InputType,
    OutputType,
    RequestType: RequestMessage,
    ResponseType: ResponseMessage
>: Interceptor {
    func modifyBeforeSigning(context: some MutableRequest<InputType, RequestType>) async throws {
        guard let key = Self.objectKey(from: context.getInput()),
              key.hasSuffix("/"),
              let request = context.getRequest() as? HTTPRequest,
              !request.path.hasSuffix("/") else { return }
        let updated = request.toBuilder().withPath(request.path + "/").build()
        guard let typed = updated as? RequestType else { return }
        context.updateRequest(updated: typed)
    }

    private static func objectKey(from input: Any) -> String? {
        switch input {
        case let value as PutObjectInput: return value.key
        case let value as DeleteObjectInput: return value.key
        case let value as HeadObjectInput: return value.key
        case let value as GetObjectInput: return value.key
        case let value as GetObjectTaggingInput: return value.key
        case let value as GetObjectAclInput: return value.key
        case let value as CopyObjectInput: return value.key
        default: return nil
        }
    }
}
