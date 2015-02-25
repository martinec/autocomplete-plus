{CompositeDisposable, Disposable} = require('atom')
ScopedPropertyStore = require('scoped-property-store')
_ = require('underscore-plus')

# Deferred requires
SymbolProvider = null
FuzzyProvider =  null

module.exports =
class ProviderManager
  fuzzyProvider: null
  fuzzyRegistration: null
  store: null
  subscriptions: null
  globalBlacklist: null

  constructor: ->
    @subscriptions = new CompositeDisposable
    @globalBlacklist = new CompositeDisposable
    @providers = new Map
    @store = new ScopedPropertyStore
    @subscriptions.add(atom.config.observe('autocomplete-plus.enableBuiltinProvider', (value) => @toggleFuzzyProvider(value)))
    @subscriptions.add(atom.config.observe('autocomplete-plus.scopeBlacklist', (value) => @setGlobalBlacklist(value)))

  dispose: ->
    @toggleFuzzyProvider(false)
    @globalBlacklist?.dispose()
    @globalBlacklist = null
    @blacklist = null
    @subscriptions?.dispose()
    @subscriptions = null
    @store?.cache = {}
    @store?.propertySets = []
    @store = null
    @providers?.clear()
    @providers = null

  providersForScopeDescriptor: (scopeDescriptor) =>
    scopeChain = scopeDescriptor?.getScopeChain?() or scopeDescriptor
    return [] unless scopeChain? and @store?
    return [] if _.contains(@blacklist, scopeChain) # Check Blacklist For Exact Match

    providers = @store.getAll(scopeChain)

    # Check Global Blacklist For Match With Selector
    blacklist = _.chain(providers).map((p) -> p.value.globalBlacklist).filter((p) -> p? and p is true).value()
    return [] if blacklist? and blacklist.length

    # Determine Blacklisted Providers
    blacklistedProviders = _.chain(providers).filter((p) -> p.value.blacklisted? and p.value.blacklisted is true).map((p) -> p.value.provider).value()
    fuzzyProviderBlacklisted = _.chain(providers).filter((p) -> p.value.providerblacklisted? and p.value.providerblacklisted is 'autocomplete-plus-fuzzyprovider').map((p) -> p.value.provider).value() if @fuzzyProvider?

    # Exclude Blacklisted Providers
    providers = _.chain(providers).filter((p) -> not p.value.blacklisted?).sortBy((p) -> -p.scopeSelector.length).map((p) -> p.value.provider).uniq().difference(blacklistedProviders).value()
    providers = _.without(providers, @fuzzyProvider) if fuzzyProviderBlacklisted? and fuzzyProviderBlacklisted.length and @fuzzyProvider?
    providers

  toggleFuzzyProvider: (enabled) =>
    return unless enabled?

    if enabled
      return if @fuzzyProvider? or @fuzzyRegistration?
      if atom.config.get('autocomplete-plus.defaultProvider') is 'Symbol'
        SymbolProvider ?= require('./symbol-provider')
        @fuzzyProvider = new SymbolProvider()
      else
        FuzzyProvider ?= require('./fuzzy-provider')
        @fuzzyProvider = new FuzzyProvider()
      @fuzzyRegistration = @registerProvider(@fuzzyProvider)
    else
      @fuzzyRegistration.dispose() if @fuzzyRegistration?
      @fuzzyProvider.dispose() if @fuzzyProvider?
      @fuzzyRegistration = null
      @fuzzyProvider = null

  setGlobalBlacklist: (@blacklist) =>
    @globalBlacklist.dispose() if @globalBlacklist?
    @globalBlacklist = new CompositeDisposable
    @blacklist = [] unless @blacklist?
    return unless @blacklist.length
    properties = {}
    properties[blacklist.join(',')] = {globalBlacklist: true}
    registration = @store.addProperties('globalblacklist', properties)
    @globalBlacklist.add(registration)

  isValidProvider: (provider, apiVersion) ->
    # TODO API: Check based on the apiVersion
    provider? and _.isFunction(provider.requestHandler) and _.isString(provider.selector) and !!provider.selector.length

  apiVersionForProvider: (provider) =>
    @providers.get(provider)

  isProviderRegistered: (provider) ->
    @providers.has(provider)

  addProvider: (provider, apiVersion='2.0.0') =>
    return if @isProviderRegistered(provider)
    @providers.set(provider, apiVersion)
    @subscriptions.add(provider) if provider.dispose?

  removeProvider: (provider) =>
    @providers.delete(provider)
    @subscriptions.remove(provider) if provider.dispose?

  registerProvider: (provider, apiVersion='2.0.0') =>
    return unless @isValidProvider(provider, apiVersion)
    return if @isProviderRegistered(provider)

    # TODO API: Deprecate the 1.0 APIs

    @addProvider(provider, apiVersion)

    properties = {}
    properties[provider.selector] = {provider}
    registration = @store.addProperties(null, properties)

    # Register Provider's Blacklist (If Present)
    blacklistRegistration = null
    if provider.blacklist?.length
      blacklistproperties = {}
      blacklistproperties[provider.blacklist] = {provider, blacklisted: true}
      blacklistRegistration = @store.addProperties(null, blacklistproperties)

    # Register Provider's Provider Blacklist (If Present)
    providerblacklistRegistration = null
    if provider.providerblacklist?['autocomplete-plus-fuzzyprovider']?.length
      providerblacklist = provider.providerblacklist['autocomplete-plus-fuzzyprovider']
      if providerblacklist.length
        providerblacklistproperties = {}
        providerblacklistproperties[providerblacklist] = {provider, providerblacklisted: 'autocomplete-plus-fuzzyprovider'}
        providerblacklistRegistration = @store.addProperties(null, providerblacklistproperties)

    disposable = new Disposable =>
      registration?.dispose()
      blacklistRegistration?.dispose()
      providerblacklistRegistation?.dispose()
      @removeProvider(provider)

    # When the provider is disposed, remove its registration
    if originalDispose = provider.dispose
      provider.dispose = ->
        originalDispose.call(provider)
        disposable.dispose()

    disposable
