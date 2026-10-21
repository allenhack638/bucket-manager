import ClientRuntime
import Smithy
import SmithyHTTPAPI

/// S3-compatible providers (Linode, MinIO, and others) sometimes compute the
/// SigV4 canonical request without the SDK-only `x-id` query parameter. The
/// AWS SDK adds it during serialization, so we remove it before signing.
struct StripXIDInterceptorProvider: InterceptorProvider {
    func create<
        InputType,
        OutputType,
        RequestType: RequestMessage,
        ResponseType: ResponseMessage
    >() -> any Interceptor<InputType, OutputType, RequestType, ResponseType> {
        StripXIDInterceptor<InputType, OutputType, RequestType, ResponseType>()
    }
}

struct StripXIDInterceptor<
    InputType,
    OutputType,
    RequestType: RequestMessage,
    ResponseType: ResponseMessage
>: Interceptor {
    func modifyBeforeSigning(context: some MutableRequest<InputType, RequestType>) async throws {
        guard let request = context.getRequest() as? HTTPRequest,
              let queryItems = request.queryItems,
              queryItems.contains(where: { $0.name == "x-id" }) else { return }
        let filtered = queryItems.filter { $0.name != "x-id" }
        let updated = request.toBuilder().replacingQueryItems(filtered).build()
        guard let typed = updated as? RequestType else { return }
        context.updateRequest(updated: typed)
    }
}
