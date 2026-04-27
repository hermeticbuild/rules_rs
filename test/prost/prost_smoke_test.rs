use echo_proto::echo::{
    EchoRequest,
    echo_service_client::EchoServiceClient,
};

#[test]
fn generated_message_and_grpc_client_types_are_available() {
    let request = EchoRequest {
        message: "hello".to_owned(),
    };
    let client_type = std::any::type_name::<EchoServiceClient<()>>();

    assert_eq!(request.message, "hello");
    assert!(client_type.contains("EchoServiceClient"));
}
