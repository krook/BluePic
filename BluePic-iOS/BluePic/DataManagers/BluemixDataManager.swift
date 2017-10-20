/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import UIKit
import BMSCore
import KituraBuddy

enum BlueMixDataManagerError: Error {
    //error when the user does not exist when we attempt to get the user by id
    case userDoesNotExist

    //error when there is a connection failure when doing a REST call
    case connectionFailure
}

extension Notification.Name {
    //Notification to notify the app that the REST call to get all images has started
    static let getAllImagesStarted = Notification.Name("GetAllImagesStarted")

    //Notification to notify the app that repulling for images has completed, the images have been refreshed
    static let imagesRefreshed = Notification.Name("ImagesRefreshed")

    //Notification to notify the app that uploading an image has began
    static let imageUploadBegan = Notification.Name("ImageUploadBegan")

    //Notification to nofify the app that Image upload was successfull
    static let imageUploadSuccess = Notification.Name("ImageUploadSuccess")

    //Notification to notify the app that image upload failed
    static let imageUploadFailure = Notification.Name("ImageUploadFailure")

    //Notificaiton used when there was a server error getting all the images
    static let getAllImagesFailure = Notification.Name("GetAllImagesFailure")

    //Notification to notify the app that the popular tags were receieved
    static let popularTagsReceived = Notification.Name("PopularTagsReceived")
}

class BluemixDataManager: NSObject {

    //Make BluemixDataManager a singlton
    static let SharedInstance: BluemixDataManager = {

        var manager = BluemixDataManager()

        return manager

    }()

    //holds all images for the app
    var images = [Image]()

    //filters images variable to only images taken by the user
    var currentUserImages: [Image] {
        return images.filter({ $0.user.id == CurrentUser.facebookUserId})
    }

    /// images that were taken during this app session (used to help make images appear faster in the image feed as we wait for the image to download from the url
    var imagesTakenDuringAppSessionById = [String: UIImage]()

    //array that stores all the images currently being uploaded. This is used to show the images currently posting on the feed
    var imagesCurrentlyUploading: [Image] = []

    //array that stores all the images that failed to upload. This is used so users can rety try uploading images that failed.
    var imagesThatFailedToUpload: [Image] = []

    //stores the most popular tags
    var tags = [PopularTag]()

    //stores all the bluemix configuration setup
    let bluemixConfig = BluemixConfiguration()

    //default timeout is 60 seconds
    fileprivate let kDefaultTimeOut: Double = 60

    //End Points
    fileprivate let kImagesEndPoint = "images"
    fileprivate let kUsersEndPoint = "users"
    fileprivate let kTagsEndPoint = "tags"
    fileprivate let kPingEndPoint = "ping"

    //used to help the feed view model decide to show the loading animaiton on the feed vc
    var hasReceievedInitialImages = false

    //used to make type safe requests to our kitura backend
    var client: KituraBuddy {
        return KituraBuddy(baseURL: getBluemixBaseRequestURL() + "/")
    }
    /**
     Method initilizes the BMSClient
     */
    func initilizeBluemixAppRoute() {

        BMSClient.sharedInstance.initialize(bluemixRegion: bluemixConfig.appRegion)
        BMSClient.sharedInstance.requestTimeout = 10.0

    }

    /**
     Method gets the Bluemix base request URL depending on if the isLocal key is set in the plist or not

     - returns: String
     */
    func getBluemixBaseRequestURL() -> String {

        if bluemixConfig.isLocal {
            return bluemixConfig.localBaseRequestURL
        } else {
            return bluemixConfig.remoteBaseRequestURL
        }
    }

}

// MARK: - Methods related to getting/creating users
extension BluemixDataManager {

    /**
     Method gets user by id and will return the parsed response in the result callback

     - parameter userId: String
     - parameter result: (user : User?, error : BlueMixDataManagerError?) -> ()
     */
    func getUserById(userId: String, result: @escaping (_ user: User?, _ error: BlueMixDataManagerError?) -> Void) {
        // Authentication might have issues?? How to pass a token? Is that necessary
        client.get(kUsersEndPoint, identifier: userId) { (user: User?, error: Error?) -> Void in
            guard let user = user, error == nil else {
                print(NSLocalizedString("Get User By ID Error:", comment : "") + " \((error ?? BlueMixDataManagerError.connectionFailure).localizedDescription)")
                result(nil, BlueMixDataManagerError.userDoesNotExist)
                return
            }
            result(user, nil)
        }
    }

    /**
     Method creates a new user and returns the parsed response in the result callback

     - parameter user: User object
     - parameter result: ((user : User?) -> ())
     */
    func createNewUser(user: User, result : @escaping (_ user: User?) -> Void) {
        client.post(kUsersEndPoint, data: user) { (user: User?, error: Error?) -> Void in
            guard let user = user, error == nil else {
                print(NSLocalizedString("Create New User Error:)", comment: "") + " \(error?.localizedDescription ?? "")")
                result(nil)
                return
            }
            result(user)
        }
    }

    /**
     Method checks to see if a user already exists, if the user doesn't exist then it creates a new user. It will return the parsed response in the callback parameter

     - parameter userId:   String
     - parameter name:     String
     - parameter callback: ((success : Bool) -> ())
     */
    func checkIfUserAlreadyExistsIfNotCreateNewUser(_ userId: String, name: String, callback : @escaping ((_ success: Bool) -> Void)) {

        getUserById(userId: userId, result: { (user, error) in

            if let error = error {

                //user does not exist so create new user
                if error == BlueMixDataManagerError.userDoesNotExist {
                    self.createNewUser(user: User(id: userId, name: name)) { user in
                      callback(user != nil)
                    }
                } else if error == BlueMixDataManagerError.connectionFailure {
                    print(NSLocalizedString("Check If User Already Exists Error: Connection Failure", comment: ""))
                    callback(false)
                }
            } else {
                callback(true)
            }

        })
    }

}

// MARK: - Methods related to gettings images
extension BluemixDataManager {

    /**
     Method gets all the images posted on BluePic. When this request begins, the GetAllImagesStarted BluemixDataManagerNotification is sent out to the app. When the images have been successfully received, the ImagesRefreshed BluemixDataManagerNotification will be sent out
     */
    func getImages() {

        NotificationCenter.default.post(name: .getAllImagesStarted, object: nil)

        client.get(kImagesEndPoint) { (images: [Image]?, error: Error?) -> Void in

            guard let images = images, error == nil else {
                print(NSLocalizedString("Get Images Error: Connection Failure", comment: ""))
                self.hasReceievedInitialImages = true
                NotificationCenter.default.post(name: .getAllImagesFailure, object: nil)
                return
            }

            self.images = images
            self.hasReceievedInitialImages = true
            NotificationCenter.default.post(name: .imagesRefreshed, object: nil)
        }
    }

    /**
     Method gets all the images by the specified tags in the tags parameter. When a response is receieved, we pass back the images we receive in the callback parameter

     - parameter tags:     [String]
     - parameter callback: (images : [Image]?)->()
     */
    func getImagesByTags(_ tags: [String], callback : @escaping (_ images: [Image]?) -> Void) {

        /* Update with Kitura buddy does not handle multiple tags*/
        let route = kImagesEndPoint + "/tag"
        client.get(route, identifier: tags.first ?? "") { (images: [Image]?, error: Error?) in
            guard let images = images, error == nil else {
                print("Error retrieving tagged images")
                callback(nil)
                return
            }
            callback(images)
        }

    }
}

// MARK: - Methods related to image uploading
extension BluemixDataManager {

    /**
     Method pings service and will be challanged if the app has App ID auth configured but the user hasn't signed in yet.

     - parameter callback: (response: Response?, error: Error?) -> Void
     */
    fileprivate func ping(_ callback : @escaping (_ response: Response?, _ error: Error?) -> Void) {

        let requestURL = getBluemixBaseRequestURL() + "/" + kPingEndPoint

        let request = Request(url: requestURL, method: HttpMethod.GET)

        request.timeout = kDefaultTimeOut

        request.send(completionHandler: callback)
    }

    /**
     Method will first call the ping method, to force the user to login with Facebook (if App ID is configured). When we get a reponse, if we have the Facebook userIdentity, then this means the user succuessfully logged into Facebook (and App ID is configured). We will then try to create a new user and when this is succuessful we finally call the postNewImage method. If we don't have the Facebook name and ID, then this means App ID isn't configured and we will continue by calling the postNewImage method as an anonymous user.

     - parameter image: Image
     */
    func tryToPostNewImage(_ image: Image) {

        addImageToImagesCurrentlyUploading(image)
        NotificationCenter.default.post(name: .imageUploadBegan, object: nil)

        //ping backend to trigger Facebook login if App ID is configured
        ping { (_, error) -> Void in

        //either there was a network failure, user authentication with facebook failed, or user authentication with facebook was canceled by the user
        guard error == nil else {
            print(NSLocalizedString("Try To Post New Image Error: Ping failed", comment: ""))
            self.handleImageUploadFailure(image)
            return
        }

        //Check if User Authenticated with Facebook (aka is App ID configured)
        guard CurrentUser.fullName != "Anonymous" && CurrentUser.facebookUserId != "anonymous" else {
            // App ID is not configured
            self.postNewImage(image)
            return
        }

        //User is authenticated with Facebook, create new user record
        let user = User(id: CurrentUser.facebookUserId, name: CurrentUser.fullName)

        self.createNewUser(user: user) { user in
            guard user != nil else {
                // Something went wrong creating new user
                print(NSLocalizedString("Try To Post New Image Error: Something went wrong calling create a new user", comment: ""))
                self.handleImageUploadFailure(image)
                return
            }

            //User Authentication complete, ready to post image
            self.postNewImage(image)
        }
      }
    }

    /**
     Method posts a new image. It will send the ImageUploadBegan notification when the image upload begins. It will send the ImageUploadSuccess notification when the image uploads successfully. For all other errors it will send out the ImageUploadFailure notification.

     - parameter image: Image
     */
    fileprivate func postNewImage(_ image: Image) {
        client.post(kImagesEndPoint, data: image) { (resImage: Image?, error: Error?) -> Void in

            guard resImage != nil, error == nil else {
                print(NSLocalizedString("Post New Image Error:", comment: "") + " \(error?.localizedDescription ?? "No image")")
                self.handleImageUploadFailure(image)
                return
            }

            self.addImageToImageTakenDuringAppSessionByIdDictionary(image)
            self.removeImageFromImagesCurrentlyUploading(image)

            NotificationCenter.default.post(name: .imageUploadSuccess, object: nil)
        }
    }

    func generateBoundaryString() -> String {
        return "Boundary-\(UUID().uuidString)"
    }

    /**
     Method handles when there is an image upload failure. It will remove the image that was uploading from the imagesCurrentlyUploading array, and then will add the image to the imagesThatFailedToUpload array. Finally it will notify the rest of the app with the BluemixDataManagerNotification.ImageUploadFailure notification

     - parameter image: Image
     */
    fileprivate func handleImageUploadFailure(_ image: Image) {

        self.removeImageFromImagesCurrentlyUploading(image)
        self.addImageToImagesThatFailedToUpload(image)

        NotificationCenter.default.post(name: .imageUploadFailure, object: nil)

    }

}

// MARK: - Methods related to uploading images
extension BluemixDataManager {

    /**
     Method will retry to upload each image in the imagesThatFailedToUpload array
     */
    func retryUploadingImagesThatFailedToUpload() {

        for image in imagesThatFailedToUpload {
            removeImageFromImagesThatFailedToUpload(image)
            tryToPostNewImage(image)

        }

    }

    /**
     Method will remove each image in the imagesThatFailedToUpload array
     */
    func cancelUploadingImagesThatFailedToUpload() {

        for image in imagesThatFailedToUpload {
            removeImageFromImagesThatFailedToUpload(image)
        }

    }

    /**
     Method will add the image parameter to the imagesThatFailedToUpload array

     - parameter image: Image
     */
    fileprivate func addImageToImagesThatFailedToUpload(_ image: Image) {

        imagesThatFailedToUpload.append(image)

    }

    /**
     Method will remove the image parameter from the imagesThatFailedToUpload array

     - parameter image: Image
     */
    fileprivate func removeImageFromImagesThatFailedToUpload(_ image: Image) {

        imagesThatFailedToUpload = imagesThatFailedToUpload.filter({ $0 != image})

    }

    /**
     Method will add the image parameter to the imagesCurrentlyUploading array

     - parameter image: Image
     */
    fileprivate func addImageToImagesCurrentlyUploading(_ image: Image) {

        imagesCurrentlyUploading.append(image)

    }

    /**
     Method will remove the image parameter from the imagesCurrentlyUploading array

     - parameter image: Image
     */
    fileprivate func removeImageFromImagesCurrentlyUploading(_ image: Image) {

        imagesCurrentlyUploading = imagesCurrentlyUploading.filter({ $0 != image})

    }

    /**
     Method adds the photo to the imagesTakenDuringAppSessionById cache to display the photo in the image feed or profile feed while we wait for the photo to upload to.
     */
    fileprivate func addImageToImageTakenDuringAppSessionByIdDictionary(_ image: Image) {

        let id = image.fileName + CurrentUser.facebookUserId
        imagesTakenDuringAppSessionById[id] = image.image

    }
}

// MARK: - Methods related to tags
extension BluemixDataManager {

    /**
     Method gets the most popular tags of BluePic. When tags receieved, it sends out the PopularTagsReceieved BluemixDataManagerNotification to the app
     */
    func getPopularTags() {
        client.get(kTagsEndPoint) { (tags: [PopularTag]?, error: Error?) -> Void in
            guard let tags = tags, error == nil else {
                print(NSLocalizedString("Get Popular Tags Error:", comment: "") + " \(error?.localizedDescription ?? "No Tags Received")")
                return
            }
            self.tags = tags
            NotificationCenter.default.post(name: .popularTagsReceived, object: nil)
        }
    }
}
