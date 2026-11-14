import ClientRuntime
import Smithy
import SmithyHTTPAPI

/// The SDK signs `Host` without the port. Normal requests still verify because
/// the SDK sends that same header, but a browser opening a presigned link on a
/// non-default port (self-hosted MinIO on :9000, for example) sends
/// `host:port`, so the server rejects the signature. Presign configs only:
/// sign the host the way a browser will send it (lowercase, with the port).
struct PresignHostPortInterceptorProvider: InterceptorProvider {
    func create<
        InputType,
        OutputType,
        RequestType: RequestMessage,
        ResponseType: ResponseMessage
    >() -> any Interceptor<InputType, OutputType, RequestType, ResponseType> {
        PresignHostPortInterceptor<InputType, OutputType, RequestType, ResponseType>()
    }
}

struct PresignHostPortInterceptor<
    InputType,
    OutputType,
    RequestType: RequestMessage,
    ResponseType: ResponseMessage
>: Interceptor {
    func modifyBeforeSigning(context: some MutableRequest<InputType, RequestType>) async throws {
        guard let request = context.getRequest() as? HTTPRequest else { return }
        // Browsers also lowercase the host, so an endpoint typed with capitals
        // ("MinIO.Example.com") must be signed in lowercase too.
        let host = request.host.lowercased()
        let port = request.destination.port.flatMap { $0 == request.destination.defaultPort ? nil : $0 }
        guard port != nil || host != request.host else { return }
        let updated = request.toBuilder()
            .updateHeader(name: "Host", value: port.map { "\(host):\($0)" } ?? host)
            .build()
        guard let typed = updated as? RequestType else { return }
        context.updateRequest(updated: typed)
    }
}
