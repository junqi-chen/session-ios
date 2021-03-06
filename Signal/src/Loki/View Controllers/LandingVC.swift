
final class LandingVC : UIViewController, LinkDeviceVCDelegate, DeviceLinkingModalDelegate {
    private var fakeChatViewContentOffset: CGPoint!
    
    // MARK: Components
    private lazy var fakeChatView: FakeChatView = {
        let result = FakeChatView()
        result.set(.height, to: Values.fakeChatViewHeight)
        return result
    }()
    
    private lazy var registerButton: Button = {
        let result = Button(style: .prominentFilled, size: .large)
        result.setTitle(NSLocalizedString("Create Session ID", comment: ""), for: UIControl.State.normal)
        result.titleLabel!.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.addTarget(self, action: #selector(register), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var restoreButton: Button = {
        let result = Button(style: .prominentOutline, size: .large)
        result.setTitle(NSLocalizedString("Continue your Session", comment: ""), for: UIControl.State.normal)
        result.titleLabel!.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.addTarget(self, action: #selector(restore), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var linkButton: Button = {
        let result = Button(style: .regularBorderless, size: .small)
        result.setTitle(NSLocalizedString("Link to an existing account", comment: ""), for: UIControl.State.normal)
        result.titleLabel!.font = .systemFont(ofSize: Values.smallFontSize)
        result.addTarget(self, action: #selector(linkDevice), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    // MARK: Settings
    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }
    
    // MARK: Lifecycle
    override func viewDidLoad() {
        // Set gradient background
        view.backgroundColor = .clear
        let gradient = Gradients.defaultLokiBackground
        view.setGradient(gradient)
        // Set up navigation bar
        let navigationBar = navigationController!.navigationBar
        navigationBar.setBackgroundImage(UIImage(), for: UIBarMetrics.default)
        navigationBar.shadowImage = UIImage()
        navigationBar.isTranslucent = false
        navigationBar.barTintColor = Colors.navigationBarBackground
        // Set up logo image view
        let logoImageView = UIImageView()
        logoImageView.image = #imageLiteral(resourceName: "SessionGreen32")
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.set(.width, to: 32)
        logoImageView.set(.height, to: 32)
        navigationItem.titleView = logoImageView
        // Set up title label
        let titleLabel = UILabel()
        titleLabel.textColor = Colors.text
        titleLabel.font = .boldSystemFont(ofSize: isSmallScreen ? Values.largeFontSize : Values.veryLargeFontSize)
        titleLabel.text = NSLocalizedString("Your Session begins here...", comment: "")
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        // Set up title label container
        let titleLabelContainer = UIView()
        titleLabelContainer.addSubview(titleLabel)
        titleLabel.pin(.leading, to: .leading, of: titleLabelContainer, withInset: Values.veryLargeSpacing)
        titleLabel.pin(.top, to: .top, of: titleLabelContainer)
        titleLabelContainer.pin(.trailing, to: .trailing, of: titleLabel, withInset: Values.veryLargeSpacing)
        titleLabelContainer.pin(.bottom, to: .bottom, of: titleLabel)
        // Set up spacers
        let topSpacer = UIView.vStretchingSpacer()
        let bottomSpacer = UIView.vStretchingSpacer()
        // Set up link button container
        let linkButtonContainer = UIView()
        linkButtonContainer.set(.height, to: Values.onboardingButtonBottomOffset)
        linkButtonContainer.addSubview(linkButton)
        linkButton.pin(.leading, to: .leading, of: linkButtonContainer, withInset: Values.massiveSpacing)
        linkButton.pin(.top, to: .top, of: linkButtonContainer)
        linkButtonContainer.pin(.trailing, to: .trailing, of: linkButton, withInset: Values.massiveSpacing)
        linkButtonContainer.pin(.bottom, to: .bottom, of: linkButton, withInset: isSmallScreen ? 6 : 10)
        // Set up button stack view
        let buttonStackView = UIStackView(arrangedSubviews: [ registerButton, restoreButton ])
        buttonStackView.axis = .vertical
        buttonStackView.spacing = isSmallScreen ? Values.smallSpacing : Values.mediumSpacing
        buttonStackView.alignment = .fill
        // Set up button stack view container
        let buttonStackViewContainer = UIView()
        buttonStackViewContainer.addSubview(buttonStackView)
        buttonStackView.pin(.leading, to: .leading, of: buttonStackViewContainer, withInset: Values.massiveSpacing)
        buttonStackView.pin(.top, to: .top, of: buttonStackViewContainer)
        buttonStackViewContainer.pin(.trailing, to: .trailing, of: buttonStackView, withInset: Values.massiveSpacing)
        buttonStackViewContainer.pin(.bottom, to: .bottom, of: buttonStackView)
        // Set up main stack view
        let mainStackView = UIStackView(arrangedSubviews: [ topSpacer, titleLabelContainer, UIView.spacer(withHeight: isSmallScreen ? Values.smallSpacing : Values.mediumSpacing), fakeChatView, bottomSpacer, buttonStackViewContainer, linkButtonContainer ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        view.addSubview(mainStackView)
        mainStackView.pin(to: view)
        topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor, multiplier: 1).isActive = true
        // Show device unlinked alert if needed
        if UserDefaults.standard[.wasUnlinked] {
            let alert = UIAlertController(title: NSLocalizedString("Device Unlinked", comment: ""), message: NSLocalizedString("Your device was unlinked successfully", comment: ""), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), accessibilityIdentifier: nil, style: .default, handler: nil))
            present(alert, animated: true, completion: nil)
            UserDefaults.removeAll()
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let fakeChatViewContentOffset = fakeChatViewContentOffset {
            fakeChatView.contentOffset = fakeChatViewContentOffset
        }
    }
    
    // MARK: Interaction
    @objc private func register() {
        fakeChatViewContentOffset = fakeChatView.contentOffset
        DispatchQueue.main.async {
            self.fakeChatView.contentOffset = self.fakeChatViewContentOffset
        }
        let registerVC = RegisterVC()
        navigationController!.pushViewController(registerVC, animated: true)
    }
    
    @objc private func restore() {
        fakeChatViewContentOffset = fakeChatView.contentOffset
        DispatchQueue.main.async {
            self.fakeChatView.contentOffset = self.fakeChatViewContentOffset
        }
        let restoreVC = RestoreVC()
        navigationController!.pushViewController(restoreVC, animated: true)
    }
    
    @objc private func linkDevice() {
        let linkDeviceVC = LinkDeviceVC()
        linkDeviceVC.delegate = self
        let navigationController = OWSNavigationController(rootViewController: linkDeviceVC)
        present(navigationController, animated: true, completion: nil)
    }
    
    // MARK: Device Linking
    func requestDeviceLink(with hexEncodedPublicKey: String) {
        guard ECKeyPair.isValidHexEncodedPublicKey(candidate: hexEncodedPublicKey) else {
            let alert = UIAlertController(title: NSLocalizedString("Invalid Public Key", comment: ""), message: NSLocalizedString("Please make sure the public key you entered is correct and try again.", comment: ""), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), accessibilityIdentifier: nil, style: .default, handler: nil))
            return present(alert, animated: true, completion: nil)
        }
        let seed = Randomness.generateRandomBytes(16)!
        let keyPair = Curve25519.generateKeyPair(fromSeed: seed + seed)
        let identityManager = OWSIdentityManager.shared()
        let databaseConnection = identityManager.value(forKey: "dbConnection") as! YapDatabaseConnection
        databaseConnection.setObject(seed.toHexString(), forKey: "LKLokiSeed", inCollection: OWSPrimaryStorageIdentityKeyStoreCollection)
        databaseConnection.setObject(keyPair, forKey: OWSPrimaryStorageIdentityKeyStoreIdentityKey, inCollection: OWSPrimaryStorageIdentityKeyStoreCollection)
        TSAccountManager.sharedInstance().phoneNumberAwaitingVerification = keyPair.hexEncodedPublicKey
        TSAccountManager.sharedInstance().didRegister()
        setUserInteractionEnabled(false)
        let _ = LokiFileServerAPI.getDeviceLinks(associatedWith: hexEncodedPublicKey).done(on: DispatchQueue.main) { [weak self] deviceLinks in
            guard let self = self else { return }
            defer { self.setUserInteractionEnabled(true) }
            guard deviceLinks.count < 2 else {
                let alert = UIAlertController(title: "Multi Device Limit Reached", message: "It's currently not allowed to link more than one device.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", accessibilityIdentifier: nil, style: .default, handler: nil))
                return self.present(alert, animated: true, completion: nil)
            }
            let appDelegate = UIApplication.shared.delegate as! AppDelegate
            appDelegate.startLongPollerIfNeeded()
            let deviceLinkingModal = DeviceLinkingModal(mode: .slave, delegate: self)
            deviceLinkingModal.modalPresentationStyle = .overFullScreen
            deviceLinkingModal.modalTransitionStyle = .crossDissolve
            self.present(deviceLinkingModal, animated: true, completion: nil)
            let linkingRequestMessage = DeviceLinkingUtilities.getLinkingRequestMessage(for: hexEncodedPublicKey)
            ThreadUtil.enqueue(linkingRequestMessage)
        }.catch(on: DispatchQueue.main) { [weak self] _ in
            let appDelegate = UIApplication.shared.delegate as! AppDelegate
            appDelegate.stopLongPollerIfNeeded()
            DispatchQueue.main.async {
                // FIXME: For some reason resetForRegistration() complains about not being on the main queue
                // without this (even though the catch closure should be executed on the main queue)
                TSAccountManager.sharedInstance().resetForReregistration()
            }
            guard let self = self else { return }
            let alert = UIAlertController(title: NSLocalizedString("Couldn't Link Device", comment: ""), message: NSLocalizedString("Please check your internet connection and try again", comment: ""), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", accessibilityIdentifier: nil, style: .default, handler: nil))
            self.present(alert, animated: true, completion: nil)
            self.setUserInteractionEnabled(true)
        }
    }
    
    func handleDeviceLinkAuthorized(_ deviceLink: DeviceLink) {
        UserDefaults.standard[.masterHexEncodedPublicKey] = deviceLink.master.hexEncodedPublicKey
        fakeChatViewContentOffset = fakeChatView.contentOffset
        DispatchQueue.main.async {
            self.fakeChatView.contentOffset = self.fakeChatViewContentOffset
        }
        let homeVC = HomeVC()
        navigationController!.setViewControllers([ homeVC ], animated: true)
    }
    
    func handleDeviceLinkingModalDismissed() {
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        appDelegate.stopLongPollerIfNeeded()
        TSAccountManager.sharedInstance().resetForReregistration()
    }
    
    // MARK: Convenience
    private func setUserInteractionEnabled(_ isEnabled: Bool) {
        [ registerButton, restoreButton, linkButton ].forEach {
            $0.isUserInteractionEnabled = isEnabled
        }
    }
}
