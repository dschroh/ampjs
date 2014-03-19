define [
  './Listener'
  'underscore'
  'jquery'
  '../util/Logger'
],
(Listener, _, $, Logger)->
  class TransportProvider
    listeners:{}
    envCallbacks: []

    constructor: (config) ->
      config = config ? {}
      @topologyService = config.topologyService ? {}
      @channelProvider = config.channelProvider ? {}

    register: (registration)->
      Logger.log.info  "TransportProvider.register >> registering new connection"
      deferred = $.Deferred()
      pendingListeners = []
      @topologyService.getRoutingInfo(registration.registrationInfo).then (routing)=>
        exchanges = _.pluck routing.routes, 'consumerExchange'

        for exchange in exchanges
          listenerDeferred = $.Deferred()
          pendingListeners.push listenerDeferred
          @_createListener(registration, exchange).then (listener)=>
            listenerDeferred.resolve()
            @listeners[registration] = listener
        $.when.apply($,pendingListeners).done ->
          Logger.log.info  "TransportProvider.register >> all listeners have been created"
          deferred.resolve()
      return deferred.promise()

    _createListener:(registration, exchange) ->
      deferred = $.Deferred()
      @channelProvider.getConnection(exchange).then (connection)=>
        listener = @_getListener(registration, exchange)

        listener.onEnvelopeReceived({
          handleRecieve: (dispatcher)=>
            Logger.log.info  "TransportProvider._createListener >> handleRecieve called"
            @raise_onEnvelopeRecievedEvent(dispatcher)
          })

        listener.onClose({
          onClose: (registration)=> delete @listeners[registration]
          })

        listener.start(connection).then ->
          Logger.log.info  "TransportProvider._createListener >> listener started"
          deferred.resolve(listener)
      return deferred.promise()

    _getListener: (registration, exchange)->
      new Listener(registration, exchange)

    _send: (connection, exchange, headers, envelope)->
      deferred = $.Deferred()
      connection.send("/exchange/#{exchange.name}/#{exchange.routingKey}",headers,envelope.getPayload())
      # TODO: how do we do error hanlding on a WebStomp.send() ??
      deferred.resolve()
      return deferred.promise()

    send: (envelope)->
      deferred = $.Deferred()
      pendingExchanges = []
      @topologyService.getRoutingInfo(envelope.getHeaders(), false).then(
        (routing)=>
          exchanges = _.pluck routing.routes, 'producerExchange'

          for exchange in exchanges
            exchangeDeferred = $.Deferred()
            pendingExchanges.push(exchangeDeferred)

            @channelProvider.getConnection(exchange).then(
              (connection, existing)=>
                newHeaders = {}
                headers = envelope.getHeaders()
                for entry of headers
                  newHeaders[entry] = headers[entry]

                Logger.log.info "TransportProvider.send >> sending message to /exchange/#{exchange.name}/#{exchange.routingKey}"

                @_send(connection, exchange, newHeaders, envelope).then(
                  () ->
                    exchangeDeferred.resolve()
                  () ->
                    exchangeDeferred.reject if arguments.length > 1 then Array.prototype.slice.call(arguments, 0) else arguments[0]
                )

              () ->
                exchangeDeferred.reject if arguments.length > 1 then Array.prototype.slice.call(arguments, 0) else arguments[0]
            )

          $.when.apply($,pendingExchanges).then(
            () ->
              deferred.resolve()
            () ->
              deferred.reject if arguments.length > 1 then Array.prototype.slice.call(arguments, 0) else arguments[0]
          )

        () ->
          deferred.reject if arguments.length > 1 then Array.prototype.slice.call(arguments, 0) else arguments[0]
      )

      return deferred.promise()

    unregister: (registration)->
      delete @listeners[registration]
    onEnvelopeRecieved: (callback)->
      @envCallbacks.push(callback)
    raise_onEnvelopeRecievedEvent: (dispatcher)->
      for callback in @envCallbacks
        callback.handleRecieve(dispatcher)
    dispose: ->
      deferred = $.Deferred()
      pendingCleanups = []
      pendingCleanups.push @channelProvider.dispose()
      pendingCleanups.push @topologyService.dispose()
      pendingCleanups.push listener.dispose() for registration, listener of @listeners

      $.when.apply($,pendingCleanups).done ->
        deferred.resolve()

      return deferred.promise()

  return TransportProvider
