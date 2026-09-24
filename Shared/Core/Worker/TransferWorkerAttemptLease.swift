// PP-127 implementation moved into TransferWorkerProtocol.swift so the shared
// execution-context helper remains available to every target that compiles the
// file-copy services, while the kernel lease itself stays macOS-only.
