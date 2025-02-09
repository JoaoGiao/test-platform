const Router = require('express')
const Config = require('./config')
const mqtt = require('mqtt')
const VfosMessagingPubsub = require('lib-messaging-pub-sub-js')

let mqttClient = null

const clientCmds = {
  reconnect: () => {
    let config = Config.get()
    if (mqttClient) {
      mqttClient.end()
      mqttClient = null
    }
    mqttClient = mqtt.connect('mqtt://' + config.mqtt_host)
    mqttClient.on('connect', function () {
      console.log('connected')
      mqttClient.subscribe(Config.get().topicList)
    })

    let platformDomain = 'pt.vfos'
    let routingKeys = ['platform']
    let communications = new VfosMessagingPubsub(config.amqp_host, config.amqp_username, platformDomain, routingKeys)

    mqttClient.on('error', function (error) {
      console.log('MQTT: Can\'t connect' + error)
      mqttClient.end()
      mqttClient = null
    })

    mqttClient.on('message', function (topic, message, packet) {
      console.log('message is ' + message)
      console.log('topic is ' + topic)
      try {
        let msgJson = JSON.parse(message)
        let q = 'pt.vfos.drivers.opc_ua.' + msgJson['_did'] + '.' + msgJson['_sid']
        communications.sendPublication(q, message)
      } catch (err) {
        console.warn(err, 'Couldn\'t parse message to JSON', message)
      }
    })
  }
}

const getClientRoutes = (app) => {
  const router = new Router()

  app.use('/rest', router)
}
Config.on('change', clientCmds.reconnect)

module.exports = { 'rest': getClientRoutes, 'obj': clientCmds }
