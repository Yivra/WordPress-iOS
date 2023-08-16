import WordPressKit

// MARK: - SiteAddressService

struct SiteAddressServiceResult {
    let hasExactMatch: Bool
    let domainSuggestions: [DomainSuggestion]
    let invalidQuery: Bool

    init(hasExactMatch: Bool = false, domainSuggestions: [DomainSuggestion] = [], invalidQuery: Bool = false) {
        self.hasExactMatch = hasExactMatch
        self.domainSuggestions = domainSuggestions
        self.invalidQuery = invalidQuery
    }
}

typealias SiteAddressServiceCompletion = (Result<SiteAddressServiceResult, Error>) -> Void

protocol SiteAddressService {
    func addresses(for query: String, segmentID: Int64, completion: @escaping SiteAddressServiceCompletion)
    func addresses(for query: String, completion: @escaping SiteAddressServiceCompletion)
}

// MARK: - MockSiteAddressService

final class MockSiteAddressService: SiteAddressService {
    func addresses(for query: String, segmentID: Int64, completion: @escaping SiteAddressServiceCompletion) {
        completion(.success(SiteAddressServiceResult(hasExactMatch: true, domainSuggestions: mockAddresses)))
    }

    func addresses(for query: String, completion: @escaping SiteAddressServiceCompletion) {
        completion(.success(SiteAddressServiceResult(hasExactMatch: true, domainSuggestions: mockAddresses)))
    }

    private let mockAddresses: [DomainSuggestion] = {
        return [ DomainSuggestion(name: "ravenclaw.wordpress.com"),
                 DomainSuggestion(name: "ravenclaw.com"),
                 DomainSuggestion(name: "team.ravenclaw.com")]
    }()
}

private extension DomainSuggestion {
    init(name: String) {
        try! self.init(json: ["domain_name": name as AnyObject])
    }
}

// MARK: - DomainsServiceAdapter

final class DomainsServiceAdapter: SiteAddressService {

    // MARK: Properties

    /// Checks if the Domain Purchasing Feature Flag and AB Experiment are enabled
    private var domainPurchasingEnabled: Bool {
        FeatureFlag.siteCreationDomainPurchasing.enabled
    }

    /**
     Corresponds to:

     Error Domain=WordPressKit.WordPressComRestApiError Code=7 "No available domains for that search." UserInfo={NSLocalizedDescription=No available domains for that search., WordPressComRestApiErrorCodeKey=empty_results, WordPressComRestApiErrorMessageKey=No available domains for that search.}
     */
    private static let emptyResultsErrorCode = 7

    /// Overrides the default quantity in the server request,
    private let domainRequestQuantity = 20

    /// The existing service for retrieving DomainSuggestions
    private let domainsService: DomainsService

    // MARK: LocalCoreDataService

    @objc convenience init(coreDataStack: CoreDataStack) {
        let api: WordPressComRestApi = coreDataStack.performQuery({
                (try? WPAccount.lookupDefaultWordPressComAccount(in: $0))?.wordPressComRestApi
            }) ?? WordPressComRestApi.defaultApi(userAgent: WPUserAgent.wordPress())

        self.init(coreDataStack: coreDataStack, api: api)
    }

    // Used to help with testing
    init(coreDataStack: CoreDataStack, api: WordPressComRestApi) {
        let remoteService = DomainsServiceRemote(wordPressComRestApi: api)
        self.domainsService = DomainsService(coreDataStack: coreDataStack, remote: remoteService)
    }

    @objc func refreshDomains(siteID: Int, completion: @escaping (Bool) -> Void) {
        domainsService.refreshDomains(siteID: siteID) { result in
            switch result {
            case .success:
                completion(true)
            case .failure:
                completion(false)
            }
        }
    }

    // MARK: SiteAddressService

    func addresses(for query: String, segmentID: Int64, completion: @escaping SiteAddressServiceCompletion) {

        domainsService.getDomainSuggestions(query: query,
                                            segmentID: segmentID,
                                            quantity: domainRequestQuantity,
                                            success: { domainSuggestions in
                                                completion(Result.success(self.sortSuggestions(for: query, suggestions: domainSuggestions)))
                                            },
                                            failure: { error in
                                                if (error as NSError).code == DomainsServiceAdapter.emptyResultsErrorCode {
                                                    completion(Result.success(SiteAddressServiceResult()))
                                                    return
                                                }

                                                completion(Result.failure(error))
                                            })
    }

    func addresses(for query: String, completion: @escaping SiteAddressServiceCompletion) {
        let domainSuggestionType: DomainsServiceRemote.DomainSuggestionType = domainPurchasingEnabled
        ? .freeAndPaid
        : .wordPressDotComAndDotBlogSubdomains
        domainsService.getDomainSuggestions(query: query,
                                            quantity: domainRequestQuantity,
                                            domainSuggestionType: domainSuggestionType,
                                            success: { domainSuggestions in
            if self.domainPurchasingEnabled {
                let hasExactMatch = domainSuggestions.contains { domain -> Bool in
                    return domain.domainNameStrippingSubdomain.caseInsensitiveCompare(query) == .orderedSame
                }
                completion(Result.success(.init(hasExactMatch: hasExactMatch, domainSuggestions: domainSuggestions)))
            } else {
                completion(Result.success(self.sortSuggestions(for: query, suggestions: domainSuggestions)))
            }
        },
                                            failure: { error in
            if (error as NSError).code == DomainsServiceAdapter.emptyResultsErrorCode {
                completion(Result.success(SiteAddressServiceResult()))
                return
            }
            if (error as NSError).code == WordPressComRestApiError.invalidQuery.rawValue {
                completion(Result.success(SiteAddressServiceResult(invalidQuery: true)))
                return
            }

            completion(Result.failure(error))
        })
    }

    private func sortSuggestions(for query: String, suggestions: [DomainSuggestion]) -> SiteAddressServiceResult {
        var hasExactMatch = false
        let sortedSuggestions = suggestions.sorted { (lhs, rhs) -> Bool in
            if lhs.domainNameStrippingSubdomain.caseInsensitiveCompare(query) == .orderedSame
                && rhs.domainNameStrippingSubdomain.caseInsensitiveCompare(query) == .orderedSame {
                // If each are an exact match sort alphabetically on the full domain and mark that we found a match
                hasExactMatch = true
                return lhs.domainName.caseInsensitiveCompare(rhs.domainName) == .orderedAscending
            } else if lhs.domainNameStrippingSubdomain.caseInsensitiveCompare(query) == .orderedSame {
                // If lhs side is a match (and rhs isn't given the previous cases) then we are sorted.
                hasExactMatch = true
                return true
            } else if rhs.domainNameStrippingSubdomain.caseInsensitiveCompare(query) == .orderedSame {
                // If rhs side is a match (and lhs isn't given the previous cases) then we are not sorted.
                hasExactMatch = true
                return false
            } else {
                // If neither rhs nor lhs ara a match then sort alphabetically
                return lhs.domainName.caseInsensitiveCompare(rhs.domainName) == .orderedAscending
            }
        }

        return SiteAddressServiceResult(hasExactMatch: hasExactMatch, domainSuggestions: sortedSuggestions)
    }
}
