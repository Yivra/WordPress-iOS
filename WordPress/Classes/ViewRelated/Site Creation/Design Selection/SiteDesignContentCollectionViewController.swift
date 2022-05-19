import Gridicons
import UIKit
import WordPressKit

class SiteDesignContentCollectionViewController: CollapsableHeaderViewController {
    typealias PreviewDevice = PreviewDeviceSelectionViewController.PreviewDevice

    private let creator: SiteCreator
    private let createsSite: Bool
    private let tableView: UITableView
    private let completion: SiteDesignStep.SiteDesignSelection

    private var sections: [SiteDesignSection] = [] {
        didSet {
            if oldValue.count == 0 {
                scrollableView.setContentOffset(.zero, animated: false)
            }
            contentSizeWillChange()
            tableView.reloadData()
        }
    }

    private var isLoading: Bool = true {
        didSet {
            if isLoading {
                tableView.startGhostAnimation(style: GhostCellStyle.muriel)
            } else {
                tableView.stopGhostAnimation()
            }

            tableView.reloadData()
        }
    }

    private var previewViewSelectedPreviewDevice = PreviewDevice.default

    private var ghostThumbnailSize: CGSize {
        return SiteDesignCategoryThumbnailSize.recommended.value
    }

    // MARK: Helper Footer View
    override var allowCustomTableFooterView: Bool {
        true
    }

    private lazy var helperView: UIView = {
        let view = UIView(frame: Metrics.helperFrame)
        view.addSubview(helperStackView)
        view.pinSubviewToAllEdges(helperStackView)
        return view
    }()

    private lazy var helperStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [helperSeparator, helperContentView])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        return stackView
    }()

    private lazy var helperSeparator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator
        return view
    }()

    private lazy var helperContentView: UIView = {
        let view = UIView()
        view.addSubview(helperContentStackView)
        view.pinSubviewToAllEdges(helperContentStackView, insets: Metrics.helperPadding)
        return view
    }()

    private lazy var helperContentStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [helperImageStackView, helperLabelStackView])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = Metrics.helperSpacing
        return stackView
    }()

    private lazy var helperImageStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [helperImageView, UIView()])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        return stackView
    }()

    private lazy var helperImageView: UIImageView = {
        let imageView = UIImageView(image: .gridicon(.infoOutline))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .secondaryLabel
        return imageView
    }()

    private lazy var helperLabelStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [helperLabel, UIView()])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        return stackView
    }()

    private lazy var helperLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = WPStyleGuide.fontForTextStyle(.body)
        label.numberOfLines = Metrics.helperTextNumberOfLines
        label.text = TextContent.helperText
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = Metrics.helperTextMinimumScaleFactor
        return label
    }()

    private func activateHelperConstraints() {
        NSLayoutConstraint.activate([
            helperImageView.heightAnchor.constraint(equalToConstant: Metrics.helperImageWidth),
            helperImageView.widthAnchor.constraint(equalToConstant: Metrics.helperImageWidth),
            helperSeparator.heightAnchor.constraint(equalToConstant: .hairlineBorderWidth)
        ])
    }

    private func setupHelperView() {
        tableView.tableFooterView = helperView
        activateHelperConstraints()

        helperSeparator.isHidden = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        helperContentView.isHidden = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        helperSeparator.isHidden = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        helperContentView.isHidden = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    let selectedPreviewDevice = PreviewDevice.mobile

    init(creator: SiteCreator, createsSite: Bool, _ completion: @escaping SiteDesignStep.SiteDesignSelection) {
        self.creator = creator
        self.createsSite = createsSite
        self.completion = completion
        tableView = UITableView(frame: .zero, style: .plain)

        super.init(
            scrollableView: tableView,
            mainTitle: TextContent.mainTitle,
            // the primary action button is never shown
            primaryActionTitle: ""
        )

        tableView.separatorStyle = .singleLine
        tableView.separatorInset = .zero
        tableView.showsVerticalScrollIndicator = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(CategorySectionTableViewCell.nib, forCellReuseIdentifier: CategorySectionTableViewCell.cellReuseIdentifier)
        tableView.dataSource = self
        navigationItem.backButtonTitle = TextContent.backButtonTitle
        configureCloseButton()
        configureSkipButton()
        SiteCreationAnalyticsHelper.trackSiteDesignViewed(previewMode: selectedPreviewDevice)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        fetchSiteDesigns()
    }

    private func fetchSiteDesigns() {
        isLoading = true

        SiteDesignSectionLoader.fetchSections(vertical: creator.vertical) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                switch result {
                case .success(let sections):
                    self.dismissNoResultsController()
                    self.sections = sections
                    self.setupHelperView()
                case .failure(let error):
                    self.handleError(error)
                }

                self.isLoading = false
            }
        }
    }

    private func configureSkipButton() {
        let skip = UIBarButtonItem(title: TextContent.skipButtonTitle, style: .done, target: self, action: #selector(skipButtonTapped))
        navigationItem.rightBarButtonItem = skip
    }

    private func configureCloseButton() {
        guard navigationController?.viewControllers.first == self else {
            return
        }

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: TextContent.cancelButtonTitle, style: .done, target: self, action: #selector(closeButtonTapped))
    }

    @objc
    private func closeButtonTapped(_ sender: Any) {
        dismiss(animated: true)
    }

    @objc
    private func skipButtonTapped(_ sender: Any) {
        presentedViewController?.dismiss(animated: true)
        SiteCreationAnalyticsHelper.trackSiteDesignSkipped()
        completion(nil)
    }

    private func handleError(_ error: Error) {
        SiteCreationAnalyticsHelper.trackError(error)
        let titleText = TextContent.errorTitle
        let subtitleText = TextContent.errorSubtitle
        displayNoResultsController(title: titleText, subtitle: subtitleText, resultsDelegate: self)
    }

    private enum TextContent {
        static let mainTitle = NSLocalizedString("Choose a theme",
                                                 comment: "Title for the screen to pick a theme and homepage for a site.")
        static let backButtonTitle = NSLocalizedString("Design",
                                                       comment: "Shortened version of the main title to be used in back navigation.")
        static let skipButtonTitle = NSLocalizedString("Skip",
                                                       comment: "Continue without making a selection.")
        static let cancelButtonTitle = NSLocalizedString("Cancel",
                                                         comment: "Cancel site creation.")
        static let errorTitle = NSLocalizedString("Unable to load this content right now.",
                                                  comment: "Informing the user that a network request failed because the device wasn't able to establish a network connection.")
        static let errorSubtitle = NSLocalizedString("Check your network connection and try again.",
                                                     comment: "Default subtitle for no-results when there is no connection.")
        static let helperText = NSLocalizedString("Can’t decide? You can change the theme at any time",
                                                  comment: "Helper text that appears at the bottom of the design screen.")
    }

    private enum Metrics {
        // Frame of the bottom helper: width will be automatically calucuated by assigning it to tableview.tableFooterView
        static let helperFrame = CGRect(x: 0, y: 0, width: 0, height: 90)
        static let helperImageWidth: CGFloat = 24.0
        static let helperPadding = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        static let helperSpacing: CGFloat = 16

        static let helperTextNumberOfLines = 2
        static let helperTextMinimumScaleFactor: CGFloat = 0.6
    }
}

// MARK: - NoResultsViewControllerDelegate

extension SiteDesignContentCollectionViewController: NoResultsViewControllerDelegate {

    func actionButtonPressed() {
        fetchSiteDesigns()
    }
}

// MARK: - UITableViewDataSource

extension SiteDesignContentCollectionViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return isLoading ? 1 : (sections.count)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cellReuseIdentifier = CategorySectionTableViewCell.cellReuseIdentifier
        guard let cell = tableView.dequeueReusableCell(withIdentifier: cellReuseIdentifier, for: indexPath) as? CategorySectionTableViewCell else {
            fatalError("Expected the cell with identifier \"\(cellReuseIdentifier)\" to be a \(CategorySectionTableViewCell.self). Please make sure the table view is registering the correct nib before loading the data")
        }
        cell.delegate = self
        cell.selectionStyle = UITableViewCell.SelectionStyle.none
        cell.section = isLoading ? nil : sections[indexPath.row]
        cell.isGhostCell = isLoading
        if isLoading {
            cell.ghostThumbnailSize = ghostThumbnailSize
        }
        cell.showsCheckMarkWhenSelected = false
        cell.layer.masksToBounds = false
        cell.clipsToBounds = false
        cell.collectionView.allowsSelection = !isLoading
        return cell
    }
}

// MARK: - CategorySectionTableViewCellDelegate

extension SiteDesignContentCollectionViewController: CategorySectionTableViewCellDelegate {

    func didSelectItemAt(_ position: Int, forCell cell: CategorySectionTableViewCell, slug: String) {
        guard let sectionIndex = sections.firstIndex(where: { $0.categorySlug == slug }) else { return }
        let design = sections[sectionIndex].designs[position]

        let previewVC = SiteDesignPreviewViewController(
            siteDesign: design,
            selectedPreviewDevice: previewViewSelectedPreviewDevice,
            createsSite: createsSite,
            onDismissWithDeviceSelected: { [weak self] device in
                self?.previewViewSelectedPreviewDevice = device
                cell.deselectItems()
            },
            completion: completion
        )

        let navController = GutenbergLightNavigationController(rootViewController: previewVC)
        navController.modalPresentationStyle = .pageSheet
        navigationController?.present(navController, animated: true)
    }

    func didDeselectItem(forCell cell: CategorySectionTableViewCell) {}

    func accessibilityElementDidBecomeFocused(forCell cell: CategorySectionTableViewCell) {
        guard UIAccessibility.isVoiceOverRunning, let cellIndexPath = tableView.indexPath(for: cell) else { return }
        tableView.scrollToRow(at: cellIndexPath, at: .middle, animated: true)
    }
}
