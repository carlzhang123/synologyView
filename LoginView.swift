import SwiftUI

struct LoginView: View {
    @Binding var serverURLString: String
    let savedServers: [String]
    @Binding var account: String
    @Binding var password: String
    @Binding var isOTPDialogPresented: Bool
    @Binding var otpCode: String
    @Binding var trustsThisDevice: Bool
    let isLoading: Bool
    let statusMessage: String
    let selectServerAction: (String) -> Void
    let loginAction: () -> Void
    let loginWithOTPAction: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                LoginHeader()

                VStack(spacing: 16) {
                    ServerField(
                        serverURLString: $serverURLString,
                        savedServers: savedServers,
                        selectServerAction: selectServerAction
                    )

                    VStack(spacing: 12) {
                        TextField("账号", text: $account)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .loginFieldStyle(systemImage: "person")

                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .loginFieldStyle(systemImage: "lock")
                    }

                    Toggle("信任此设备", isOn: $trustsThisDevice)
                        .font(.subheadline)

                    Button {
                        loginAction()
                    } label: {
                        HStack {
                            Text("登录")
                                .fontWeight(.semibold)
                            Spacer()
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.right")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isLoading || serverURLString.isEmpty || account.isEmpty || password.isEmpty)

                    Label(statusMessage, systemImage: isLoading ? "hourglass" : "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .frame(maxWidth: 460)
        }
        .navigationTitle("登录")
        .sheet(isPresented: $isOTPDialogPresented) {
            OTPPromptView(
                otpCode: $otpCode,
                trustsThisDevice: $trustsThisDevice,
                isLoading: isLoading,
                loginAction: loginWithOTPAction
            )
            .presentationDetents([.height(300)])
        }
    }
}

private struct LoginHeader: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.blue)

            VStack(spacing: 6) {
                Text("Synology View")
                    .font(.largeTitle.bold())

                Text("连接群晖 FileStation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ServerField: View {
    @Binding var serverURLString: String
    let savedServers: [String]
    let selectServerAction: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 22)

            TextField("服务器地址", text: $serverURLString)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            Menu {
                Button(SynologyLoginSettingsStore.defaultServerURLString) {
                    selectServerAction(SynologyLoginSettingsStore.defaultServerURLString)
                }

                ForEach(savedServers.filter { $0 != SynologyLoginSettingsStore.defaultServerURLString }, id: \.self) { server in
                    Button(server) {
                        selectServerAction(server)
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OTPPromptView: View {
    @Binding var otpCode: String
    @Binding var trustsThisDevice: Bool
    let isLoading: Bool
    let loginAction: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("验证码", text: $otpCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)

                    Toggle("信任此设备", isOn: $trustsThisDevice)
                } footer: {
                    Text("如果 NAS 返回设备标识，App 会保存它并在后续登录时尝试跳过两步验证。")
                }
            }
            .navigationTitle("两步验证")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("验证") {
                        loginAction()
                    }
                    .disabled(isLoading || otpCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LoginFieldStyle: ViewModifier {
    let systemImage: String

    func body(content: Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            content
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    func loginFieldStyle(systemImage: String) -> some View {
        modifier(LoginFieldStyle(systemImage: systemImage))
    }
}
