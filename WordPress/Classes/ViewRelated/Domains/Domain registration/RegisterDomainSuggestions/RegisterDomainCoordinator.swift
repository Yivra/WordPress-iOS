import Foundation
import AutomatticTracks

class RegisterDomainCoordinator {

    enum Error: Swift.Error {
        case noDomainWhenCreatingCart
    }

    // MARK: Type Aliases

    typealias DomainPurchasedCallback = ((UIViewController, String) -> Void)
    typealias DomainAddedToCartCallback = ((UIViewController, String, Blog) -> Void)

    // MARK: Variables

    private let crashLogger: CrashLogging

    var site: Blog?
    var domainPurchasedCallback: DomainPurchasedCallback?
    var domainAddedToCartAndLinkedToSiteCallback: DomainAddedToCartCallback?
    var domain: FullyQuotedDomainSuggestion?

    private var webViewURLChangeObservation: NSKeyValueObservation?

    init(site: Blog?,
         domainPurchasedCallback: RegisterDomainCoordinator.DomainPurchasedCallback? = nil,
         crashLogger: CrashLogging = .main) {
        self.site = site
        self.domainPurchasedCallback = domainPurchasedCallback
        self.crashLogger = crashLogger
    }

    // MARK: Public Functions

    /// Adds the selected domain to the cart then launches the checkout webview.
    /// This flow support purchasing domains only, without plans.
    func handlePurchaseDomainOnly(on viewController: UIViewController,
                                  onSuccess: @escaping () -> (),
                                  onFailure: @escaping () -> ()) {
        createCart { [weak self] result in
            switch result {
            case .success:
                guard let self else { return }
                self.presentCheckoutWebview(on: viewController, title: nil, shouldPush: false)
                onSuccess()
            case .failure:
                onFailure()
            }
        }
    }

    /// Adds the selected domain to the cart then executes `domainAddedToCartAndLinkedToSiteCallback` if set.
    func addDomainToCartLinkedToCurrentSite(on viewController: UIViewController,
                         onSuccess: @escaping () -> (),
                         onFailure: @escaping () -> ()) {
        guard let blog = site else {
            return
        }
        createCart { [weak self] result in
            switch result {
            case .success(let domain):
                self?.domainAddedToCartAndLinkedToSiteCallback?(viewController, domain.domainName, blog)
            case .failure:
                onFailure()
            }
        }
    }

    /// Related to the `purchaseFromDomainManagement` Domain selection type.
    /// Adds the selected domain to the cart then launches the checkout webview
    /// The checkout webview is configured for the domain management flow
    func handleNoSiteChoice(on viewController: UIViewController,
                            choicesViewModel: DomainPurchaseChoicesViewModel?) {
        createCart { [weak self] result in
            switch result {
            case .success:
                self?.presentCheckoutWebview(on: viewController, title: TextContent.checkoutTitle, shouldPush: true)
                choicesViewModel?.isGetDomainLoading = false

            case .failure:
                viewController.displayActionableNotice(title: TextContent.errorTitle, actionTitle: TextContent.errorDismiss)
                choicesViewModel?.isGetDomainLoading = false
            }
        }
    }

    /// Related to the `purchaseFromDomainManagement` Domain selection type.
    /// Adds the selected domain to the cart then presents a site picker view.
    func handleExistingSiteChoice(on viewController: UIViewController) {
        let config = BlogListConfiguration(shouldShowCancelButton: false,
                                           shouldShowNavBarButtons: false,
                                           navigationTitle: TextContent.sitePickerNavigationTitle,
                                           backButtonTitle: TextContent.sitePickerNavigationTitle,
                                           shouldHideSelfHostedSites: true,
                                           shouldHideBlogsNotSupportingDomains: true)
        guard let blogListViewController = BlogListViewController(configuration: config, meScenePresenter: nil) else {
            return
        }

        blogListViewController.blogSelected = { [weak self] controller, selectedBlog in
            guard let self,
                  let controller,
                  let selectedBlog else {
                return
            }
            self.site = selectedBlog
            controller.showLoading()
            self.createCart { [weak self] result in
                switch result {
                case .success(let domain):
                    self?.domainAddedToCartAndLinkedToSiteCallback?(controller, domain.domainName, selectedBlog)
                    controller.hideLoading()
                case .failure:
                    controller.displayActionableNotice(title: TextContent.errorTitle, actionTitle: TextContent.errorDismiss)
                    controller.hideLoading()
                }
            }
        }

        viewController.navigationController?.pushViewController(blogListViewController, animated: true)
    }

    // MARK: Helpers

    private func createCart(completion: @escaping (Result<FullyQuotedDomainSuggestion, Swift.Error>) -> Void) {
        guard let domain else {
            completion(.failure(Error.noDomainWhenCreatingCart))
            return
        }
        let siteID = site?.dotComID?.intValue
        let proxy = RegisterDomainDetailsServiceProxy()
        proxy.createPersistentDomainShoppingCart(siteID: siteID,
                                                 domainSuggestion: domain.remoteSuggestion(),
                                                 privacyProtectionEnabled: domain.supportsPrivacy ?? false,
                                                 success: { _ in
            completion(.success(domain))
        },
                                                 failure: { error in
            completion(.failure(error))
        })
    }

    private func presentCheckoutWebview(on viewController: UIViewController,
                                        title: String?,
                                        shouldPush: Bool) {
        guard let domain,
              let url = checkoutURL() else {
            crashLogger.logMessage("Failed to present domain checkout webview.",
                                   level: .error)
            return
        }

        let webViewController = WebViewControllerFactory.controllerWithDefaultAccountAndSecureInteraction(
            url: url,
            source: "domains_register", // TODO: Update source
            title: title)
        let navController = LightNavigationController(rootViewController: webViewController)

        // WORKAROUND: The reason why we have to use this mechanism to detect success and failure conditions
        // for domain registration is because our checkout process (for some unknown reason) doesn't trigger
        // call to WKWebViewDelegate methods.
        //
        // This was last checked by @diegoreymendez on 2021-09-22.
        //
        webViewURLChangeObservation = webViewController.webView.observe(\.url, options: .new) { [weak self] _, change in
            guard let self = self,
                  let newURL = change.newValue as? URL else {
                return
            }

            self.handleWebViewURLChange(newURL, domain: domain.domainName, onCancel: {
                if shouldPush {
                    viewController.navigationController?.popViewController(animated: true)
                } else {
                    navController.dismiss(animated: true)
                }
            }) { domain in
                self.domainPurchasedCallback?(viewController, domain)
            }
        }

        if let site {
            WPAnalytics.track(.domainsPurchaseWebviewViewed, properties: WPAnalytics.domainsProperties(for: site), blog: site)
        } else {
            // TODO: Track showing no site checkout
        }

        webViewController.configureSandboxStore {
            if shouldPush {
                viewController.navigationController?.pushViewController(webViewController, animated: true)
            } else {
                viewController.present(navController, animated: true)
            }
        }
    }

    private func checkoutURL() -> URL? {
        if let site {
            guard let homeURL = site.homeURL,
                  let siteUrl = URL(string: homeURL as String), let host = siteUrl.host,
                  let url = URL(string: Constants.checkoutWebAddress + host) else {
                return nil
            }
            return url
        } else {
            return URL(string: Constants.noSiteCheckoutWebAddress)
        }
    }

    /// Handles URL changes in the web view.  We only allow the user to stay within certain URLs.  Falling outside these URLs
    /// results in the web view being dismissed.  This method also handles the success condition for a successful domain registration
    /// through said web view.
    ///
    /// - Parameters:
    ///     - newURL: the newly set URL for the web view.
    ///     - domain: the domain the user is purchasing.
    ///     - onCancel: the closure that will be executed if we detect the conditions for cancelling the registration were met.
    ///     - onSuccess: the closure that will be executed if we detect a successful domain registration.
    ///
    private func handleWebViewURLChange(
        _ newURL: URL,
        domain: String,
        onCancel: () -> Void,
        onSuccess: (String) -> Void) {

        let canOpenNewURL = newURL.absoluteString.starts(with: Constants.checkoutWebAddress)

        guard canOpenNewURL else {
            onCancel()
            return
        }

        let domainRegistrationSucceeded = newURL.absoluteString.starts(with: Constants.checkoutSuccessURLPrefix)

        if domainRegistrationSucceeded {
            onSuccess(domain)

        }
    }
}

// MARK: - Constants
extension RegisterDomainCoordinator {

    enum TextContent {
        static let errorTitle = NSLocalizedString("domains.failure.title",
                                                  value: "Sorry, the domain you are trying to add cannot be bought on the Jetpack app at this time.",
                                                  comment: "Content show when the domain selection action fails.")
        static let errorDismiss = NSLocalizedString("domains.failure.dismiss",
                                                    value: "Dismiss",
                                                    comment: "Action shown in a bottom notice to dismiss it.")
        static let checkoutTitle = NSLocalizedString("domains.checkout.title",
                                                     value: "Checkout",
                                                     comment: "Title for the checkout screen.")
        static let sitePickerNavigationTitle = NSLocalizedString("domains.sitePicker.title",
                                                                 value: "Choose Site",
                                                                 comment: "Title of screen where user chooses a site to connect to their selected domain")
    }

    enum Constants {
        static let checkoutWebAddress = "https://wordpress.com/checkout/"
        static let noSiteCheckoutWebAddress = "https://wordpress.com/checkout/no-site?isDomainOnly=1"
        static let checkoutSuccessURLPrefix = "https://wordpress.com/checkout/thank-you/"
    }
}
