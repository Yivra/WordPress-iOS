import WordPressUI

class PrepublishingSocialAccountsViewController: UITableViewController {

    // MARK: Properties

    private let coreDataStack: CoreDataStack

    private let blogID: Int

    private var connections: [Connection]

    private let sharingLimit: PublicizeInfo.SharingLimit?

    private var shareMessage: String {
        didSet {
            messageCell.detailTextLabel?.text = shareMessage
        }
    }

    var onContentHeightUpdated: (() -> Void)? = nil

    private var isSharingLimitReached: Bool = false {
        didSet {
            guard oldValue != isSharingLimitReached else {
                return // no need to reload if the value doesn't change.
            }
            // only reload connections that are turned off.
            // the last toggled row is skipped so it can perform its full switch animation.
            tableView.reloadRows(at: indexPathsForDisabledConnections.filter { $0.row != lastToggledRow }, with: .none)
        }
    }

    /// Store the last table row toggled by the user.
    private var lastToggledRow: Int = -1

    private lazy var messageCell: UITableViewCell = {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: Constants.messageCellIdentifier)
        WPStyleGuide.configureTableViewCell(cell)

        cell.textLabel?.text = Constants.messageCellLabelText
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.text = shareMessage
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            cell.detailTextLabel?.numberOfLines = 3
        }
        cell.accessoryType = .disclosureIndicator

        return cell
    }()

    // MARK: Methods

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(blogID: Int, model: PrepublishingAutoSharingModel, coreDataStack: CoreDataStack = ContextManager.shared) {
        self.blogID = blogID
        self.connections = model.services.flatMap { service in
            service.connections.map {
                .init(service: service.name, account: $0.account, keyringID: $0.keyringID, isOn: $0.enabled)
            }
        }
        self.shareMessage = model.message
        self.sharingLimit = model.sharingLimit
        self.coreDataStack = coreDataStack

        super.init(style: .insetGrouped)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = Constants.navigationTitle

        tableView.register(SwitchTableViewCell.self, forCellReuseIdentifier: Constants.accountCellIdentifier)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // manually configure preferredContentSize for precise drawer sizing.
        if let safeAreaInsets = UIApplication.shared.mainWindow?.safeAreaInsets {
            preferredContentSize = CGSize(width: tableView.contentSize.width,
                                          height: tableView.contentSize.height + safeAreaInsets.bottom + 16.0)
            onContentHeightUpdated?()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // when the vertical size class changes, ensure that we are displaying the max drawer height on compact size
        // or revert to collapsed mode otherwise.
        if let previousVerticalSizeClass = previousTraitCollection?.verticalSizeClass,
           previousVerticalSizeClass != traitCollection.verticalSizeClass {
            presentedVC?.transition(to: traitCollection.verticalSizeClass == .compact ? .expanded : .collapsed)
        }
    }
}

// MARK: - UITableView

extension PrepublishingSocialAccountsViewController {

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return connections.count + 1 // extra row for the sharing message
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row < connections.count {
            return accountCell(for: indexPath)
        }

        return messageCell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // interactions for the account switches are absorbed by the tap gestures set up in the SwitchTableViewCell,
        // so it shouldn't trigger this method. In any case, we should only care about handling taps on the message row.
        guard indexPath.row == connections.count else {
            return
        }

        showEditMessageScreen()
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let sharingLimit else {
            return nil
        }

        return PrepublishingSocialAccountsTableFooterView(remaining: sharingLimit.remaining,
                                                          showsWarning: shouldDisplayWarning,
                                                          onButtonTap: { [weak self] in
            self?.subscribeButtonTapped()
        })
    }
}

// MARK: - Private Helpers

private extension PrepublishingSocialAccountsViewController {

    var enabledCount: Int {
        connections.filter { $0.isOn }.count
    }

    var indexPathsForDisabledConnections: [IndexPath] {
        connections.indexed().compactMap { $1.isOn ? nil : IndexPath(row: $0, section: .zero) }
    }

    var shouldDisplayWarning: Bool {
        guard let sharingLimit else {
            return false
        }
        return connections.count >= sharingLimit.remaining
    }

    func accountCell(for indexPath: IndexPath) -> UITableViewCell {
        guard var connection = connections[safe: indexPath.row],
              let cell = tableView.dequeueReusableCell(withIdentifier: Constants.accountCellIdentifier) as? SwitchTableViewCell else {
            return UITableViewCell()
        }

        cell.textLabel?.text = connection.account
        cell.textLabel?.numberOfLines = 1
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.imageView?.image = connection.imageForCell
        cell.on = connection.isOn
        cell.onChange = { [weak self] newValue in
            self?.updateConnection(at: indexPath.row, enabled: newValue)
        }

        let isInteractionAllowed = connection.isOn || !isSharingLimitReached
        isInteractionAllowed ? cell.enable() : cell.disable()
        cell.imageView?.alpha = isInteractionAllowed ? 1.0 : Constants.disabledCellImageOpacity

        cell.accessibilityLabel = "\(connection.service.description), \(connection.account)"

        return cell
    }

    func updateConnection(at index: Int, enabled: Bool) {
        guard index < connections.count else {
            return
        }

        // directly mutate the value to avoid copy-on-write.
        connections[index].isOn = enabled
        lastToggledRow = index

        toggleInteractivityIfNeeded()
    }

    func toggleInteractivityIfNeeded() {
        guard let sharingLimit else {
            // if sharing limit does not exist, then interactions should be unlimited.
            isSharingLimitReached = false
            return
        }

        isSharingLimitReached = enabledCount >= sharingLimit.remaining
    }

    func showEditMessageScreen() {
        let multiTextViewController = SettingsMultiTextViewController(text: shareMessage,
                                                                      placeholder: nil,
                                                                      hint: Constants.editShareMessageHint,
                                                                      isPassword: false)

        multiTextViewController.title = Constants.editShareMessageNavigationTitle
        multiTextViewController.onValueChanged = { [weak self] newValue in
            self?.shareMessage = newValue
        }

        self.navigationController?.pushViewController(multiTextViewController, animated: true)
    }

    func subscribeButtonTapped() {
        guard let checkoutViewController = makeCheckoutViewController() else {
            return
        }

        let navigationController = UINavigationController(rootViewController: checkoutViewController)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)

        // TODO: Flag to sync on viewDidAppear in case the user has made a purchase.
    }

    func makeCheckoutViewController() -> UIViewController? {
        coreDataStack.performQuery { [weak self] context in
            guard let self,
                  let blog = try? Blog.lookup(withID: self.blogID, in: context),
                  let host = blog.hostname,
                  let url = URL(string: "https://wordpress.com/checkout/\(host)/jetpack_social_basic_yearly") else {
                return nil
            }

            return WebViewControllerFactory.controller(url: url, blog: blog, source: Constants.webViewSource)
        }
    }

    /// Convenient model that represents the user's Publicize connections.
    struct Connection {
        let service: PublicizeService.ServiceName
        let account: String
        let keyringID: Int
        var isOn: Bool

        lazy var imageForCell: UIImage = {
            service.localIconImage.resizedImage(with: .scaleAspectFit,
                                                bounds: Constants.cellImageSize,
                                                interpolationQuality: .default)
        }()
    }

    // MARK: Constants

    enum Constants {
        static let disabledCellImageOpacity = 0.36
        static let cellImageSize = CGSize(width: 28.0, height: 28.0)

        static let accountCellIdentifier = "AccountCell"
        static let messageCellIdentifier = "MessageCell"

        static let webViewSource = "prepublishing_social_accounts_subscribe"

        static let navigationTitle = NSLocalizedString(
            "prepublishing.socialAccounts.navigationTitle",
            value: "Social",
            comment: "The navigation title for the pre-publishing social accounts screen."
        )

        static let messageCellLabelText = NSLocalizedString(
            "prepublishing.socialAccounts.message.label",
            value: "Message",
            comment: """
                The label displayed for a table row that displays the sharing message for the post.
                Tapping on this row allows the user to edit the sharing message.
                """
        )

        static let editShareMessageNavigationTitle = NSLocalizedString(
            "prepublishing.socialAccounts.editMessage.navigationTitle",
            value: "Customize message",
            comment: "The navigation title for a screen that edits the sharing message for the post."
        )

        static let editShareMessageHint = NSLocalizedString(
            "prepublishing.socialAccounts.editMessage.hint",
            value: """
                Customize the message you want to share.
                If you don't add your own text here, we'll use the post's title as the message.
                """,
            comment: "A hint shown below the text field when editing the sharing message from the pre-publishing flow."
        )
    }

}

extension PrepublishingSocialAccountsViewController: DrawerPresentable {

    var collapsedHeight: DrawerHeight {
        .intrinsicHeight
    }

    var scrollableView: UIScrollView? {
        tableView
    }
}
