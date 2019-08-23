'use strict'

const Router = require('express')
const fs = require('fs')
const Asset = require('../model/Asset')
const exec = require('child_process').exec

const clrId = function (id) {
  return id.replace('vfos_', '').replace('_1', '')
}

const reload = function (id, killOnly) {
  let asset = Asset.readConfigFile(id)
  return asset.reloadAll(killOnly)
}
const dropPersistence = function (id) {
  let asset = Asset.readConfigFile(id)
  return asset.deletePersistence()
}

const openCalls = {}
let callCache = function (call, duration) {
  /*
   *  call is a string for exec(call,  )
   *  Client calls wrapper, with callback that expects a promise
   *
   *  (result is a promise, allowing errors to propagate)
   *  if (result & timestamp too old) drop result, reset timestamp
   *  if !flag (set flag + start call)
   *
   *  if (result) callbackPromise.resolve(result)
   *  add to waiters
   *
   *  When call returns, set result, set timestamp, call all waiters, remove flag
   */
  let doCall = function (cache) {
    cache.flag = true
    exec(call, (error, stdout, stderr) => {
      if (error) {
        cache.waiters.map((waiter) => {
          waiter(Promise.reject(error, stderr))
        })
      } else {
        cache.result = stdout
        cache.timestamp = Date.now()
        cache.flag = false
        cache.waiters.map((waiter) => {
          waiter(Promise.resolve(stdout))
        })
      }
      cache.waiters = []
    })
  }
  if (!openCalls[call]) {
    openCalls[call] = { 'result': null, 'waiters': [], 'flag': false, 'timestamp': -1 }
  }
  let cache = openCalls[call]
  if (cache.result && Date.now() - cache.timestamp > duration) {
    cache.result = null
    cache.timestamp = -1
  }
  if (Date.now() - cache.timestamp > (duration / 2) && !cache.flag) {
    doCall(cache)
  }
  return new Promise((resolve, reject) => {
    let callback = (resPromise) => {
      resPromise.then((result) => { resolve(result) }).catch((error) => { reject(error) })
    }
    if (cache.result) {
      callback(Promise.resolve(cache.result))
    } else {
      cache.waiters.push(callback)
    }
  })
}

const getAssetRoutes = (app) => {
  const router = new Router()

  function getFullInfo (res) {
    let dumpcmd = '/usr/src/app/dump_info.sh'
    callCache(dumpcmd, 3000).then((stdout) => {
      res.setHeader('Content-Type', 'application/json')
      res.send(stdout)
    }).catch((error, stderr) => {
      res.setHeader('Content-Type', 'application/json')
      res.status(500)
      res.send({
        'error': error, 'stderr': stderr
      })
    })
  }

  router
    .get('/', (req, res) => {
      getFullInfo(res)
    })
    .get('/full', (req, res) => {
      getFullInfo(res)
    })
    .get('/stats', (req, res) => {
      // We want to execute this command line:
      //      docker stats --no-stream --format "{\"containerID\":\"{{ .Container }}\", \"name\":\"{{ .Name }}\", \"cpu\":\"{{ .CPUPerc }}\", \"mem\":\"{{ .MemUsage }}\", \"memPerc\":\"{{ .MemPerc }}\", \"netIO\":\"{{ .NetIO }}\", \"blockIO\":\"{{ .BlockIO }}\", \"pids\":\"{{ .PIDs }}\"}"
      let strFormat = {
        'containerID': '{{ .Container }}',
        'name': '{{ .Name }}',
        'cpu': '{{ .CPUPerc }}',
        'mem': '{{ .MemUsage }}',
        'memPerc': '{{ .MemPerc }}',
        'netIO': '{{ .NetIO }}',
        'blockIO': '{{ .BlockIO }}',
        'pids': '{{ .PIDs }}'
      }
      let statsCommand = 'docker stats --no-stream --format \'' + JSON.stringify(strFormat) + '\''
      callCache(statsCommand, 3000).then((stdout) => {
        let answer = {
          'stdout': stdout,
          'timestamp': Date.now()
        }
        // send answer
        res.setHeader('Content-Type', 'application/json')
        res.send(answer)
      }).catch((error, stderr) => {
        res.setHeader('Content-Type', 'application/json')
        res.status(500)
        res.send({
          'error': error, 'stderr': stderr
        })
      })
    })
    .post('/logs', (req, res) => {
      let logsCommand = 'docker logs ' + req.body.containerName + ' | tail -n ' + req.body.numOfLines

      // let logsCommand = 'export TERM=linux-m1b;docker logs ' + req.body.containerName + ' | tail -n ' + req.body.numOfLines;
      // let logsCommand = 'docker exec vf_os_platform_exec_control docker-compose --file test_compose.yml logs --no-color assetA'
      callCache(logsCommand, 3000).then((stdout) => {
        let answer = {
          'stdout': stdout,
          'timestamp': Date.now()
        }
        // send answer
        res.setHeader('Content-Type', 'application/json')
        res.send(answer)
      }).catch((error, stderr) => {
        res.setHeader('Content-Type', 'application/json')
        res.status(500)
        res.send({
          'error': error, 'stderr': stderr
        })
      })
    })
    .get('/:id/compose_config', (req, res) => {
      // just get the file from disk
      let id = clrId(req.params.id)
      res.setHeader('Content-Type', 'application/x-yaml')
      let readStream = fs.createReadStream('/var/run/compose/3_' + id + '_compose.yml')
      readStream.pipe(res)
    })
    .post('/:id/reload', (req, res) => {
      let id = clrId(req.params.id)
      reload(id).then(() => {
        res.send({ result: 'OK' })
      }).catch((err, stderr) => {
        res.setHeader('Content-Type', 'application/json')
        res.status(500)
        res.send({ error: err, stderr: stderr })
      })
    })
    .post('/:id/reset', (req, res) => {
      let id = clrId(req.params.id)
      dropPersistence(id).then((result) => {
        reload(id).then(() => {
          res.send({ result: result })
        }).catch((err, stderr) => {
          res.setHeader('Content-Type', 'application/json')
          res.status(500)
          res.send({ error: err, stderr: stderr })
        })
      }).catch((error) => {
        res.setHeader('Content-Type', 'application/json')
        res.status(500)
        res.send({ error: error })
      })
    })
    .get('/:id', async (req, res) => {
      let id = clrId(req.params.id)
      res.setHeader('Content-Type', 'application/json')
      res.send(Asset.readConfigFile(id))
    })
    .post('/:id', async (req, res) => {
      let id = clrId(req.params.id)
      try {
        let data = req.body
        let asset = Asset.readConfigFile(id)
        if (asset) {
          if (data.id) {
            asset.id = clrId(data.id)
          }
          asset.imageId = data.imageId
          let output = await asset.writeConfigFile()
          reload(id).then(() => {
            res.send({ result: 'OK', output: output })
          }).catch((err, stderr) => {
            res.setHeader('Content-Type', 'application/json')
            res.status(500)
            res.send({
              error: err,
              stderr: stderr
            })
          })
        } else {
          res.setHeader('Content-Type', 'application/json')
          res.status(404)
          res.send({ 'error': 'Cannot find asset:' + req.params.id })
        }
      } catch (e) {
        res.setHeader('Content-Type', 'application/json')
        res.status(500)
        res.send({ error: e })
      }
    })
    .put('/', async (req, res) => {
      try {
        let data = req.body
        let id = clrId(data.id)
        let asset = Asset.readConfigFile(id)
        if (!asset) {
          asset = new Asset(id, data.imageId)
        }
        if (data.imageId) {
          asset.imageId = data.imageId
        }
        let output = await asset.writeConfigFile()
        reload(id).then(() => {
          res.send({ result: 'OK', output: output })
        }).catch((err, stderr) => {
          res.status(500)
          res.send({
            error: err.toString(),
            stderr: stderr
          })
        })
      } catch (e) {
        res.setHeader('Content-Type', 'application/json')
        res.status(500)
        res.send({ error: e.toString() })
      }
    })
    .delete('/:id', async (req, res) => {
      let id = clrId(req.params.id)
      dropPersistence(id).then(() => {
        reload(id, true).then(() => {
          if (fs.existsSync('/var/run/compose/3_' + id + '_compose.yml')) {
            fs.unlinkSync('/var/run/compose/3_' + id + '_compose.yml')
          }
          res.send({ result: 'OK' })
        })
      }).catch((err, stderr) => {
        res.status(500)
        res.send({
          error: err.toString(),
          stderr: stderr
        })
      })
    })

  app.use('/assets', router)
}

module.exports = getAssetRoutes
