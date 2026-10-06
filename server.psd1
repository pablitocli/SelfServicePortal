@{
    # Pode server configuration (read automatically from the portal root).
    Server = @{
        Request = @{
            # Seconds Pode waits for a request to be received/processed before answering 408.
            # vCenter connection tests from the Admin page can take up to 60 s.
            Timeout  = 180
            BodySize = 10MB
        }
    }
}
