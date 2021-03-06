Docker = require 'dockerode'
DockerProgress = require 'docker-progress'
Promise = require 'bluebird'
config = require './config'
_ = require 'lodash'
knex = require './db'

docker = Promise.promisifyAll(new Docker(socketPath: config.dockerSocket))
# Hack dockerode to promisify internal classes' prototypes
Promise.promisifyAll(docker.getImage().constructor.prototype)
Promise.promisifyAll(docker.getContainer().constructor.prototype)

exports.docker = docker
dockerProgress = new DockerProgress(socketPath: config.dockerSocket)

do ->
	# Keep track of the images being fetched, so we don't clean them up whilst fetching.
	imagesBeingFetched = 0
	exports.fetchImageWithProgress = (image, onProgress) ->
		imagesBeingFetched++
		dockerProgress.pull(image, onProgress)
		.finally ->
			imagesBeingFetched--

	supervisorTag = config.supervisorImage
	if !/:/g.test(supervisorTag)
		# If there is no tag then mark it as latest
		supervisorTag += ':latest'
	exports.cleanupContainersAndImages = ->
		Promise.join(
			knex('app').select()
			.map (app) ->
				app.imageId + ':latest'
			docker.listImagesAsync()
			(apps, images) ->
				imageTags = _.map(images, 'RepoTags')
				supervisorTags = _.filter imageTags, (tags) ->
					_.contains(tags, supervisorTag)
				appTags = _.filter imageTags, (tags) ->
					_.any tags, (tag) ->
						_.contains(apps, tag)
				supervisorTags = _.flatten(supervisorTags)
				appTags = _.flatten(appTags)
				return { images, supervisorTags, appTags }
		)
		.then ({ images, supervisorTags, appTags }) ->
			# Cleanup containers first, so that they don't block image removal.
			docker.listContainersAsync(all: true)
			.filter (containerInfo) ->
				# Do not remove user apps.
				if _.contains(appTags, containerInfo.Image)
					return false
				if !_.contains(supervisorTags, containerInfo.Image)
					return true
				return containerHasExited(containerInfo.Id)
			.map (containerInfo) ->
				docker.getContainer(containerInfo.Id).removeAsync()
				.then ->
					console.log('Deleted container:', containerInfo.Id, containerInfo.Image)
				.catch (err) ->
					console.log('Error deleting container:', containerInfo.Id, containerInfo.Image, err)
			.then ->
				# And then clean up the images, as long as we aren't currently trying to fetch any.
				return if imagesBeingFetched > 0
				imagesToClean = _.reject images, (image) ->
					_.any image.RepoTags, (tag) ->
						return _.contains(appTags, tag) or _.contains(supervisorTags, tag)
				Promise.map imagesToClean, (image) ->
					Promise.map image.RepoTags.concat(image.Id), (tag) ->
						docker.getImage(tag).removeAsync()
						.then ->
							console.log('Deleted image:', tag, image.Id, image.RepoTags)
						.catch (err) ->
							console.log('Error deleting image:', tag, image.Id, image.RepoTags, err)

	containerHasExited = (id) ->
		docker.getContainer(id).inspectAsync()
		.then (data) ->
			return not data.State.Running

