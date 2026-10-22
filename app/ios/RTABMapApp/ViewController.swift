//
//  ViewController.swift
//  GLKittutorial
//
//  Created by Mathieu Labbe on 2020-12-28.
//

import GLKit
import ARKit
import AVFoundation
import CoreImage
import ImageIO
import Zip
import StoreKit

extension Array {
    func size() -> Int {
        return MemoryLayout<Element>.stride * self.count
    }
}

class ViewController: GLKViewController, ARSessionDelegate, RTABMapObserver, UIPickerViewDataSource, UIPickerViewDelegate, CLLocationManagerDelegate {
    
    private let session = ARSession()
    let scanRecorder = ScanRecorder()
    var photoButton: UIButton?
    private var locationManager: CLLocationManager?
    private var mLastKnownLocation: CLLocation?
    private var mLastLightEstimate: CGFloat?
    
    private var context: EAGLContext?
    private var rtabmap: RTABMap?
    
    private var databases = [URL]()
    private var currentDatabaseIndex: Int = 0
    private var openedDatabasePath: URL?
    
    private var progressDialog: UIAlertController?
    var progressView : UIProgressView?
    
    var maxPolygonsPickerView: UIPickerView!
    var maxPolygonsPickerData: [Int]!
    
    private var mTotalLoopClosures: Int = 0
    private var mMapNodes: Int = 0
    private var mTimeThr: Int = 0
    private var mMaxFeatures: Int = 0
    private var mLoopThr = 0.11
    private var mDataRecording = false
    
    private var mReviewRequested = false
    
    private var mMaximumMemory: Int = 0
    
    // UI states
    private enum State {
        case STATE_WELCOME,    // Camera/Motion off - showing only buttons open and start new scan
        STATE_CAMERA,          // Camera/Motion on - not mapping
        STATE_MAPPING,         // Camera/Motion on - mapping
        STATE_IDLE,            // Camera/Motion off
        STATE_PROCESSING,      // Camera/Motion off - post processing
        STATE_VISUALIZING,     // Camera/Motion off - Showing optimized mesh
        STATE_VISUALIZING_CAMERA,     // Camera/Motion on  - Showing optimized mesh and localizing
        STATE_VISUALIZING_WHILE_LOADING, // Camera/Motion off - Loading data while showing optimized mesh
        STATE_VISUALIZING_AND_MEASURING    // Camera/Motion on  - Showing optimized mesh without localizing and measuring tools enabled
    }
    private var mState: State = State.STATE_WELCOME;
    private func getStateString(state: State) -> String {
        switch state {
        case .STATE_WELCOME:
            return "Welcome"
        case .STATE_CAMERA:
            return "Camera Preview"
        case .STATE_MAPPING:
            return mDataRecording ? "Data Recording" : "Mapping"
        case .STATE_PROCESSING:
            return "Processing"
        case .STATE_VISUALIZING:
            return "Visualizing"
        case .STATE_VISUALIZING_CAMERA:
            return "Visualizing with Camera"
        case .STATE_VISUALIZING_WHILE_LOADING:
            return "Visualizing while Loading"
        case .STATE_VISUALIZING_AND_MEASURING:
            return "Measuring"
        default: // IDLE
            return "Idle"
        }
    }
    
    private var depthSupported: Bool = false
    
    private var viewMode: Int = 2 // 0=Cloud, 1=Mesh, 2=Textured Mesh
    private var cameraMode: Int = 1
    
    private var statusShown: Bool = true
    private var debugShown: Bool = false
    private var mapShown: Bool = true
    private var odomShown: Bool = true
    private var graphShown: Bool = true
    private var gridShown: Bool = true
    private var optimizedGraphShown: Bool = true
    private var wireframeShown: Bool = false
    private var backfaceShown: Bool = false
    private var lightingShown: Bool = false
    private var textureColorSeamsShown: Bool = false
    private var mHudVisible: Bool = true
    private var mLastTimeHudShown: DispatchTime = .now()
    private var mMenuOpened: Bool = false
    private var lowMemoryWarningShown: Bool = false
    static var previewImages: [String: UIImage] = [:]
    private var measuringMode: Int = 0
    private var visualizationType: Int = 0 // 0=Cloud, 1=Mesh, 2=Texture Mesh
    
    @IBOutlet weak var stopButton: UIButton!
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var menuButton: UIButton!
    @IBOutlet weak var viewButton: UIButton!
    @IBOutlet weak var newScanButtonLarge: UIButton!
    @IBOutlet weak var libraryButton: UIButton!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var closeVisualizationButton: UIButton!
    @IBOutlet weak var stopCameraButton: UIButton!
    @IBOutlet weak var stopMeasuringButton: UIButton!
    @IBOutlet weak var teleportButton: UIButton!
    @IBOutlet weak var addMeasureButton: UIButton!
    @IBOutlet weak var removeMeasureButton: UIButton!
    @IBOutlet weak var measuringModeButton: UIButton!
    @IBOutlet weak var exportOBJPLYButton: UIButton!
    @IBOutlet weak var orthoDistanceSlider: UISlider!{
        didSet{
            orthoDistanceSlider.transform = CGAffineTransform(rotationAngle: CGFloat(-Double.pi/2))
        }
    }
    @IBOutlet weak var orthoGridSlider: UISlider!
    @IBOutlet weak var toastLabel: UILabel!
    
    let RTABMAP_TMP_DB = "rtabmap.tmp.db"
    let RTABMAP_RECOVERY_DB = "rtabmap.tmp.recovery.db"
    let RTABMAP_EXPORT_DIR = "Export"

    func getDocumentDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func getTmpDirectory() -> URL {
       return URL(fileURLWithPath: NSTemporaryDirectory())
    }
    
    @objc func defaultsChanged(){
        print("defaultsChanged()")
        updateDisplayFromDefaults()
    }
    
    func showToast(message : String, seconds: Double){
        // Logged even when not shown: a visible toast hides the next one
        scanRecorder.event("ilmoitus", message)
        if(!self.toastLabel.isHidden)
        {
            return;
        }
        self.toastLabel.text = message
        self.toastLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + seconds) {
            self.toastLabel.isHidden = true
        }
    }
    
    func resetNoTouchTimer(_ showHud: Bool = false) {
        if(showHud)
        {
            mMenuOpened = false
            mHudVisible = true
            setNeedsStatusBarAppearanceUpdate()
            updateState(state: self.mState)
            
            mLastTimeHudShown = DispatchTime.now()
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 5) {
                if(DispatchTime.now() <= self.mLastTimeHudShown + 4.9) {
                    return
                }
                if(self.mState != .STATE_WELCOME && self.mState != .STATE_CAMERA && self.presentedViewController as? UIAlertController == nil && !self.mMenuOpened)
                {
                    print("Hide HUD")
                    self.mHudVisible = false
                    self.setNeedsStatusBarAppearanceUpdate()
                    self.updateState(state: self.mState)
                }
            }
        }
        else if(mState != .STATE_WELCOME && mState != .STATE_CAMERA && presentedViewController as? UIAlertController == nil && !mMenuOpened)
        {
            self.mHudVisible = false
            self.setNeedsStatusBarAppearanceUpdate()
            self.updateState(state: self.mState)
        }
    }
    
    func addShadow(_ view: UIView, _ offset: Int = 4)
    {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowRadius = 3.0
        view.layer.shadowOpacity = 1.0
        view.layer.shadowOffset = CGSize(width: offset, height: offset)
        view.layer.masksToBounds = false
    }
    
    override func viewDidLoad() {
        
        mMaximumMemory = getAvailableMemory()
        
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        setupScanRecorder()
        
        self.toastLabel.isHidden = true
        session.delegate = self
        
        addShadow(stopButton)
        addShadow(recordButton)
        addShadow(menuButton)
        addShadow(viewButton)
        addShadow(newScanButtonLarge)
        addShadow(libraryButton)
        addShadow(closeVisualizationButton)
        addShadow(stopCameraButton)
        addShadow(stopMeasuringButton)
        addShadow(teleportButton)
        addShadow(addMeasureButton)
        addShadow(removeMeasureButton)
        addShadow(measuringModeButton)
        addShadow(exportOBJPLYButton)
        
        addShadow(statusLabel, 0)
        addShadow(toastLabel, 0)
        
        addShadow(orthoDistanceSlider, 0)
        addShadow(orthoGridSlider, 0)
        
        depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        
        rtabmap = RTABMap()
        rtabmap?.setupCallbacksWithCPP()
        
        context = EAGLContext(api: .openGLES2)
        EAGLContext.setCurrent(context)
        
        if let view = self.view as? GLKView, let context = context {
            view.context = context
            delegate = self
            rtabmap?.initGlContent()
        }
        
        menuButton.showsMenuAsPrimaryAction = true
        viewButton.showsMenuAsPrimaryAction = true
        statusLabel.numberOfLines = 0
        statusLabel.text = ""
        
        updateDatabases()
        
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        singleTap.numberOfTapsRequired = 1
        view.addGestureRecognizer(singleTap)
        
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.willResignActiveNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        
        rtabmap!.addObserver(self)
        
        registerSettingsBundle()
        updateDisplayFromDefaults()
        
        maxPolygonsPickerView = UIPickerView(frame: CGRect(x: 10, y: 50, width: 250, height: 150))
        maxPolygonsPickerView.delegate = self
        maxPolygonsPickerView.dataSource = self

        // This is where you can set your min/max values
        let minNum = 0
        let maxNum = 9
        maxPolygonsPickerData = Array(stride(from: minNum, to: maxNum + 1, by: 1))
        
        orthoDistanceSlider.setValue(80, animated: false)
        orthoGridSlider.setValue(90, animated: false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.updateState(state: self.mState)
        }
    }

    func progressStatusUpdate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.mState == .STATE_PROCESSING && self.statusShown
            {
                let availableMem = self.getAvailableMemory()
                let usedMem = self.mMaximumMemory - availableMem;
                self.statusLabel.text =
                    "Status: \(self.getStateString(state: self.mState))\n" +
                    "RAM Usage (MB): \(usedMem) / \(self.mMaximumMemory)"
                self.progressStatusUpdate()
            }
        }
    }
    
    func progressUpdated(_ rtabmap: RTABMap, count: Int, max: Int) {
        DispatchQueue.main.async {
            self.progressView?.setProgress(Float(count)/Float(max), animated: true)
        }
    }
    func initEventReceived(_ rtabmap: RTABMap, status: Int, msg: String) {
        DispatchQueue.main.async {
            var optimizedMeshDetected = 0

            if(msg == "Loading optimized cloud...done!")
            {
                optimizedMeshDetected = 1;
            }
            else if(msg == "Loading optimized mesh...done!")
            {
                optimizedMeshDetected = 2;
            }
            else if(msg == "Loading optimized texture mesh...done!")
            {
                optimizedMeshDetected = 3;
            }
            if(optimizedMeshDetected > 0)
            {
                if(optimizedMeshDetected==1)
                {
                    self.visualizationType = 0;
                    self.setMeshRendering(viewMode: 0)
                }
                else if(optimizedMeshDetected==2)
                {
                    self.visualizationType = 1;
                    self.setMeshRendering(viewMode: 1)
                }
                else // isOBJ
                {
                    self.visualizationType = 2;
                    self.setMeshRendering(viewMode: 2)
                }

                self.updateState(state: .STATE_VISUALIZING_WHILE_LOADING);
                self.setGLCamera(type: 2);
                
                self.dismiss(animated: true)
                self.showToast(message: "Optimized mesh detected in the database, it is shown while the database is loading...", seconds: 3)
            }

            let availableMem = self.getAvailableMemory()
            let usedMem = self.mMaximumMemory - availableMem;
            self.statusLabel.text =
                "Status: " + (status == 1 && msg.isEmpty ? self.mState == State.STATE_CAMERA ? "Camera Preview" : "Idle" : msg) + "\n" +
            	"RAM Usage (MB): \(usedMem) / \(self.mMaximumMemory)"
        }
    }
        
    func statsUpdated(_ rtabmap: RTABMap,
                           nodes: Int,
                           words: Int,
                           points: Int,
                           polygons: Int,
                           updateTime: Float,
                           loopClosureId: Int,
                           highestHypId: Int,
                           databaseMemoryUsed: Int,
                           inliers: Int,
                           matches: Int,
                           featuresExtracted: Int,
                           hypothesis: Float,
                           nodesDrawn: Int,
                           fps: Float,
                           rejected: Int,
                           rehearsalValue: Float,
                           optimizationMaxError: Float,
                           optimizationMaxErrorRatio: Float,
                           distanceTravelled: Float,
                           fastMovement: Int,
                           landmarkDetected: Int,
                           x: Float,
                           y: Float,
                           z: Float,
                           roll: Float,
                           pitch: Float,
                           yaw: Float)
    {
        let availableMem = self.getAvailableMemory()
        let usedMem = self.mMaximumMemory - availableMem;
        
        if(loopClosureId > 0)
        {
            mTotalLoopClosures += 1;
        }
        let previousNodes = mMapNodes
        mMapNodes = nodes;
        
        let formattedDate = Date().getFormattedDate(format: "HH:mm:ss.SSS")
        
        DispatchQueue.main.async {
            
            if(self.mMapNodes>0 && previousNodes==0 && self.mState != .STATE_MAPPING)
            {
                self.updateState(state: self.mState) // refesh menus and actions
            }
            self.scanRecorder.stats(nodes: nodes, nodesDrawn: nodesDrawn, words: words, points: points, polygons: polygons,
                                    updateTime: updateTime, fps: fps, databaseMemoryUsed: databaseMemoryUsed)

            self.statusLabel.text = ""
            if self.statusShown {
                self.statusLabel.text =
                    self.statusLabel.text! +
                    "Status: \(self.getStateString(state: self.mState))\n" +
                	"RAM Usage (MB): \(usedMem) / \(self.mMaximumMemory)"
            }
            if self.debugShown {
                self.statusLabel.text =
                    self.statusLabel.text! + "\n"
                var gpsString = "\n"
                if(UserDefaults.standard.bool(forKey: "SaveGPS"))
                {
                    if(self.mLastKnownLocation != nil)
                    {
                        let secondsOld = (Date().timeIntervalSince1970 - self.mLastKnownLocation!.timestamp.timeIntervalSince1970)
                        var bearing = 0.0
                        if(self.mLastKnownLocation!.course > 0.0) {
                            bearing = self.mLastKnownLocation!.course
                            
                        }
                        gpsString = String(format: "GPS: %.2f %.2f %.2fm %ddeg %.0fm [%d sec old]\n",
                                           self.mLastKnownLocation!.coordinate.longitude,
                                           self.mLastKnownLocation!.coordinate.latitude,
                                           self.mLastKnownLocation!.altitude,
                                           Int(bearing),
                                           self.mLastKnownLocation!.horizontalAccuracy,
                                           Int(secondsOld));
                    }
                    else
                    {
                        gpsString = "GPS: [not yet available]\n";
                    }
                }
                var lightString = "\n"
                if(self.mLastLightEstimate != nil)
                {
                    lightString = String("Light (lm): \(Int(self.mLastLightEstimate!))\n")
                }
                
                self.statusLabel.text =
                    self.statusLabel.text! +
                    gpsString + //gps
                    lightString + //env sensors
                    "Time: \(formattedDate)\n" +
                    "Nodes (WM): \(nodes) (\(nodesDrawn) shown)\n" +
                    "Words: \(words)\n" +
                    "Database (MB): \(databaseMemoryUsed)\n" +
                    "Number of points: \(points)\n" +
                    "Polygons: \(polygons)\n" +
                    "Update time (ms): \(Int(updateTime)) / \(self.mTimeThr==0 ? "No Limit" : String(self.mTimeThr))\n" +
                    "Features: \(featuresExtracted) / \(self.mMaxFeatures==0 ? "No Limit" : (self.mMaxFeatures == -1 ? "Disabled" : String(self.mMaxFeatures)))\n" +
                    "Rehearsal (%): \(Int(rehearsalValue*100))\n" +
                    "Loop closures: \(self.mTotalLoopClosures)\n" +
                    "Inliers: \(inliers)\n" +
                    "Hypothesis (%): \(Int(hypothesis*100)) / \(Int(self.mLoopThr*100)) (\(loopClosureId>0 ? loopClosureId : highestHypId))\n" +
                    String(format: "FPS (rendering): %.1f Hz\n", fps) +
                    String(format: "Travelled distance: %.2f m\n", distanceTravelled) +
                    String(format: "Pose (x,y,z): %.2f %.2f %.2f", x, y, z)
            }
            if(self.mState == .STATE_MAPPING || self.mState == .STATE_VISUALIZING_CAMERA)
            {
                if(loopClosureId > 0) {
                    if(self.mState == .STATE_VISUALIZING_CAMERA) {
                        self.showToast(message: "Localized!", seconds: 1);
                    }
                    else {
                        self.showToast(message: "Loop closure detected!", seconds: 1);
                    }
                }
                else if(rejected > 0)
                {
                    if(inliers >= UserDefaults.standard.integer(forKey: "MinInliers"))
                    {
                        if(optimizationMaxError > 0.0)
                        {
                            self.showToast(message: String(format: "Loop closure rejected, too high graph optimization error (%.3fm: ratio=%.3f < factor=%.1fx).", optimizationMaxError, optimizationMaxErrorRatio, UserDefaults.standard.float(forKey: "MaxOptimizationError")), seconds: 1);
                        }
                        else
                        {
                            self.showToast(message: String(format: "Loop closure rejected, graph optimization failed! You may try a different Graph Optimizer (see Mapping options)."), seconds: 1);
                        }
                    }
                    else
                    {
                        self.showToast(message: String(format: "Loop closure rejected, not enough inliers (%d/%d < %d).", inliers, matches, UserDefaults.standard.integer(forKey: "MinInliers")), seconds: 1);
                    }
                }
                else if(landmarkDetected > 0) {
                    self.showToast(message: "Landmark \(landmarkDetected) detected!", seconds: 1);
                }
            }
            if(self.mState == .STATE_MAPPING)
            {
                if(availableMem < 400)
                {
                    let msg = "Scanning will be stopped because the free memory is too "
                    + "low (\(availableMem) MB). You should be able to save the database but some post-processing and exporting options may fail. "
                    + "\n\nNote that for large environments, you can save multiple databases and "
                    + "merge them with RTAB-Map Desktop version."
                    self.scanRecorder.event("halytys", "Memory is full: \(availableMem) MB free, scanning will be stopped")
                    let alert = UIAlertController(title: "Memory is full!", message: msg, preferredStyle: .alert)
                    let alertActionYes = UIAlertAction(title: "Ok", style: .default) {
                        (UIAlertAction) -> Void in
                        self.stopMapping(ignoreSaving: false, offerPostProcessing: false, reason: "memory full (under 400 MB free)");
                    }
                    alert.addAction(alertActionYes)
                    self.present(alert, animated: true, completion: nil)
                }
                else if(!self.lowMemoryWarningShown && usedMem*3 > availableMem && !self.mDataRecording)
                {
                    self.lowMemoryWarningShown = true
                    let msg = "Available memory (\(availableMem) MB) should be at least 3 times the "
                    + "memory used (\(usedMem) MB) so that some post-processing and exporting options "
                    + "have enough memory to work correctly. If you just want to save the database "
                    + "after scanning, you can continue until the next warning.\n\n"
                    + "Note that showing only point clouds and/or decrease density reduce memory needed for rendering."
                    self.scanRecorder.event("halytys", "Memory warning: \(availableMem) MB free, \(usedMem) MB used (free under 3x used)")
                    let alert = UIAlertController(title: "Memory is full!", message: msg, preferredStyle: .alert)
                    let alertActionYes = UIAlertAction(title: "Stop Now", style: .default) {
                        (UIAlertAction) -> Void in
                        self.stopMapping(ignoreSaving: false, reason: "memory warning: Stop Now");
                    }
                    alert.addAction(alertActionYes)
                    let alertActionNo = UIAlertAction(title: "Continue", style: .cancel) {
                        (UIAlertAction) -> Void in
                        self.scanRecorder.event("valinta", "memory warning: Continue")
                    }
                    alert.addAction(alertActionNo)
                    self.present(alert, animated: true, completion: nil)
                }
            }
        }
    }
    
    func cameraInfoEventReceived(_ rtabmap: RTABMap, type: Int, key: String, value: String) {
        if(key == "UpstreamRelocationFiltered")
        {
            scanRecorder.event("arkit_hyppy_suodatettu", "acceleration \(value)")
        }
        if(self.debugShown && key == "UpstreamRelocationFiltered")
        {
            DispatchQueue.main.async {
                self.dismiss(animated: true)
                self.showToast(message: "ARKit re-localization filtered because an acceleration of \(value) has been detected, which is over current threshold set in the settings.", seconds: 3)
            }
        }
    }
    
    func getAvailableMemory() -> Int {
        return os_proc_available_memory()/(1024*1024)
    }
    
    @objc func appMovedToBackground() {
        print("appMovedToBackground()")
        if(mState == .STATE_VISUALIZING_CAMERA || mState == .STATE_VISUALIZING_AND_MEASURING || mState == .STATE_MAPPING || mState == .STATE_CAMERA)
        {
            stopMapping(ignoreSaving: true, reason: "app resigned active (background, Control Center, alert or camera stop)")
        }
    }
    
    @objc func appMovedToForeground() {
        print("appMovedToForeground()")
        updateDisplayFromDefaults()
        updateState(state: mState)
        
        if(mMapNodes > 0 && self.openedDatabasePath == nil)
        {
            let msg = "RTAB-Map has been pushed to background while mapping. Do you want to save the map now?"
            let alert = UIAlertController(title: mDataRecording ? "Data Recording Stopped" : "Mapping Stopped!", message: msg, preferredStyle: .alert)
            let alertActionNo = UIAlertAction(title: "Ignore", style: .cancel) {
                (UIAlertAction) -> Void in
            }
            alert.addAction(alertActionNo)
            let alertActionYes = UIAlertAction(title: "Yes", style: .default) {
                (UIAlertAction) -> Void in
                self.save()
            }
            alert.addAction(alertActionYes)
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    func setMeshRendering(viewMode: Int)
    {
        switch viewMode {
        case 0:
            self.rtabmap?.setMeshRendering(enabled: false, withTexture: false)
        case 1:
            self.rtabmap?.setMeshRendering(enabled: true, withTexture: false)
        default:
            self.rtabmap?.setMeshRendering(enabled: true, withTexture: true)
        }
        self.viewMode = viewMode
        updateState(state: mState)
    }
    
    func setGLCamera(type: Int)
    {
        cameraMode = type
        rtabmap!.setCamera(type: type);
    }
    
    func startCamera()
    {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: // The user has previously granted access to the camera.
                print("Start Camera")
            	rtabmap!.startCamera()
                let configuration = ARWorldTrackingConfiguration()
                var message = ""
            	if(mState != .STATE_VISUALIZING_AND_MEASURING)
            	{
                	if(!UserDefaults.standard.bool(forKey: "LidarMode"))
                	{
       		        	message = "LiDAR is disabled (Settings->Mapping->LiDAR Mode = OFF), only tracked features will be mapped."
       		        	self.setMeshRendering(viewMode: 0)
        	    	}
                	else if !depthSupported
                	{
                    	message = "The device does not have a LiDAR, only tracked features will be mapped. A LiDAR is required for accurate 3D reconstruction."
                    	self.setMeshRendering(viewMode: 0)
                	}
                	else
                	{
                    	configuration.frameSemantics = .sceneDepth
                	}
            	}
                if #available(iOS 16.0, *), ScanRecorder.highResFormatEnabled,
                   let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
                    configuration.videoFormat = format
                }
                
                session.run(configuration, options: [.resetSceneReconstruction, .resetTracking, .removeExistingAnchors])
                
                switch mState {
                case .STATE_VISUALIZING_AND_MEASURING,
                    .STATE_VISUALIZING_CAMERA:
                    break // State should be already set
                default:
                    locationManager?.startUpdatingLocation()
                    updateState(state: .STATE_CAMERA)
                }
                
                if(!message.isEmpty)
                {
                    let alertController = UIAlertController(title: "Start Camera", message: message, preferredStyle: .alert)
                    let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
                    }
                    alertController.addAction(okAction)
                    present(alertController, animated: true)
                }
            
            case .notDetermined: // The user has not yet been asked for camera access.
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        DispatchQueue.main.async {
                            self.startCamera()
                        }
                    }
                }
            
        default:
            let alertController = UIAlertController(title: "Camera Disabled", message: "Camera permission is required to start the camera. You can enable it in Settings.", preferredStyle: .alert)

            let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }
                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                        print("Settings opened: \(success)") // Prints true
                    })
                }
            }
            alertController.addAction(settingsAction)
            
            let okAction = UIAlertAction(title: "Ignore", style: .default) { (action) in
            }
            alertController.addAction(okAction)
            
            present(alertController, animated: true)
        }
    }
    
    private func updateState(state: State)
    {
        print("State: \(state)")
        
        if(mState != state)
        {
            mState = state;
            resetNoTouchTimer(true)
            return
        }
        
        mState = state;

        var actionNewScanEnabled: Bool
        var actionNewDataRecording: Bool
        var actionSaveEnabled: Bool
        var actionResumeEnabled: Bool
        var actionExportEnabled: Bool
        var actionOptimizeEnabled: Bool
        var actionSettingsEnabled: Bool
        var actionMeasuringEnabled: Bool
        
        switch mState {
        case .STATE_CAMERA:
            libraryButton.isEnabled = false
            libraryButton.isHidden = false
            menuButton.isHidden = false
            viewButton.isHidden = false
            newScanButtonLarge.isHidden = true // WELCOME button
            recordButton.isHidden = false
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
            stopCameraButton.isHidden = false
            stopMeasuringButton.isHidden = true
            exportOBJPLYButton.isHidden = true
            orthoDistanceSlider.isHidden = cameraMode != 3
            orthoGridSlider.isHidden = cameraMode != 3
            teleportButton.isHidden = true
            addMeasureButton.isHidden = true
            removeMeasureButton.isHidden = true
            measuringModeButton.isHidden = true
            actionNewScanEnabled = !mDataRecording
            actionNewDataRecording = mDataRecording
            actionSaveEnabled = false
            actionResumeEnabled = false
            actionExportEnabled = false
            actionOptimizeEnabled = false
            actionSettingsEnabled = false
            actionMeasuringEnabled = false
        case .STATE_MAPPING:
            libraryButton.isEnabled = false
            libraryButton.isHidden = !mHudVisible
            menuButton.isHidden = !mHudVisible
            viewButton.isHidden = !mHudVisible
            newScanButtonLarge.isHidden = true // WELCOME button
            recordButton.isHidden = true
            stopButton.isHidden = false
            closeVisualizationButton.isHidden = true
            stopCameraButton.isHidden = true
            stopMeasuringButton.isHidden = true
            exportOBJPLYButton.isHidden = true
            orthoDistanceSlider.isHidden = cameraMode != 3 || !mHudVisible
            orthoGridSlider.isHidden = cameraMode != 3 || !mHudVisible
            teleportButton.isHidden = true
            addMeasureButton.isHidden = true
            removeMeasureButton.isHidden = true
            measuringModeButton.isHidden = true
            actionNewScanEnabled = !mDataRecording
            actionNewDataRecording = mDataRecording
            actionSaveEnabled = false
            actionResumeEnabled = false
            actionExportEnabled = false
            actionOptimizeEnabled = false
            actionSettingsEnabled = false
            actionMeasuringEnabled = false
        case .STATE_PROCESSING,
             .STATE_VISUALIZING_WHILE_LOADING,
             .STATE_VISUALIZING_CAMERA,
             .STATE_VISUALIZING_AND_MEASURING:
            libraryButton.isEnabled = false
            libraryButton.isHidden = !mHudVisible
            menuButton.isHidden = !mHudVisible
            viewButton.isHidden = !mHudVisible
            newScanButtonLarge.isHidden = true // WELCOME button
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
            stopCameraButton.isHidden = mState != .STATE_VISUALIZING_CAMERA
            stopMeasuringButton.isHidden = mState != .STATE_VISUALIZING_AND_MEASURING
            exportOBJPLYButton.isHidden = true
            orthoDistanceSlider.isHidden = cameraMode != 3 || mState == .STATE_PROCESSING
            orthoGridSlider.isHidden = cameraMode != 3 || mState == .STATE_PROCESSING
            teleportButton.isHidden = mState != .STATE_VISUALIZING_AND_MEASURING || cameraMode != 0
            addMeasureButton.isHidden = mState != .STATE_VISUALIZING_AND_MEASURING || cameraMode == 3
            removeMeasureButton.isHidden = mState != .STATE_VISUALIZING_AND_MEASURING || cameraMode == 3
            measuringModeButton.isHidden = true
            actionNewScanEnabled = false
            actionNewDataRecording = false
            actionSaveEnabled = false
            actionResumeEnabled = false
            actionExportEnabled = false
            actionOptimizeEnabled = false
            actionSettingsEnabled = false
            actionMeasuringEnabled = mState == .STATE_VISUALIZING_AND_MEASURING
        case .STATE_VISUALIZING:
            libraryButton.isEnabled = !databases.isEmpty
            libraryButton.isHidden = !mHudVisible
            menuButton.isHidden = !mHudVisible
            viewButton.isHidden = !mHudVisible
            newScanButtonLarge.isHidden = true // WELCOME button
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = !mHudVisible
            stopCameraButton.isHidden = true
            stopMeasuringButton.isHidden = true
            exportOBJPLYButton.isHidden = !mHudVisible
            orthoDistanceSlider.isHidden = cameraMode != 3 || !mHudVisible
            orthoGridSlider.isHidden = cameraMode != 3 || !mHudVisible
            teleportButton.isHidden = true
            addMeasureButton.isHidden = true
            removeMeasureButton.isHidden = true
            measuringModeButton.isHidden = !mHudVisible || self.visualizationType==0
            actionNewScanEnabled = true
            actionNewDataRecording = true
            actionSaveEnabled = mMapNodes>0
            actionResumeEnabled = mMapNodes>0
            actionExportEnabled = mMapNodes>0
            actionOptimizeEnabled = mMapNodes>0
            actionSettingsEnabled = true
            actionMeasuringEnabled = true
        default: // IDLE // WELCOME
            libraryButton.isEnabled = !databases.isEmpty
            libraryButton.isHidden = mState != .STATE_WELCOME && !mHudVisible
            menuButton.isHidden = mState != .STATE_WELCOME && !mHudVisible
            viewButton.isHidden = mState != .STATE_WELCOME && !mHudVisible
            newScanButtonLarge.isHidden = mState != .STATE_WELCOME
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
            stopCameraButton.isHidden = true
            stopMeasuringButton.isHidden = true
            exportOBJPLYButton.isHidden = true
            orthoDistanceSlider.isHidden = cameraMode != 3 || !mHudVisible
            orthoGridSlider.isHidden = cameraMode != 3 || !mHudVisible
            teleportButton.isHidden = true
            addMeasureButton.isHidden = true
            removeMeasureButton.isHidden = true
            measuringModeButton.isHidden = true
            actionNewScanEnabled = true
            actionNewDataRecording = true
            actionSaveEnabled = mState != .STATE_WELCOME && mMapNodes>0
            actionResumeEnabled = mState != .STATE_WELCOME && mMapNodes>0
            actionExportEnabled = mState != .STATE_WELCOME && mMapNodes>0
            actionOptimizeEnabled = mState != .STATE_WELCOME && mMapNodes>0
            actionSettingsEnabled = true
            actionMeasuringEnabled = false
        }

        let view = self.view as? GLKView
        if(mState != .STATE_MAPPING && mState != .STATE_CAMERA && mState != .STATE_VISUALIZING_CAMERA && mState != .STATE_VISUALIZING_AND_MEASURING)
        {
            self.isPaused = true
            view?.enableSetNeedsDisplay = true
            self.view.setNeedsDisplay()
        }
        else
        {
            view?.enableSetNeedsDisplay = false
            self.isPaused = false
        }
        
        if !self.isPaused {
            self.view.setNeedsDisplay()
        }
        
        // Update menus based on current state
        
        if(!exportOBJPLYButton.isHidden) {
            let format = UserDefaults.standard.string(forKey: "ExportPointCloudFormat")!;
            var title = "Export "
            if (self.visualizationType == 2) {
                title += "OBJ";
            }
            else if (self.visualizationType == 1)
            {
                title += "PLY";
            }
            else
            {
                title += format == "las" ? "LAS" : format == "laz" ? "LAZ" : "PLY";
            }
            self.exportOBJPLYButton.setTitle(title, for: .normal)
        }
        
        // PointCloud menu
        let pointCloudMenu = UIMenu(title: "Point cloud...", children: [
            UIAction(title: "Current Density", handler: { _ in
                self.export(isOBJ: false, meshing: false, regenerateCloud: false, optimized: false, optimizedMaxPolygons: 0, previousState: self.mState)
            }),
            UIAction(title: "Max Density", handler: { _ in
                self.export(isOBJ: false, meshing: false, regenerateCloud: true, optimized: false, optimizedMaxPolygons: 0, previousState: self.mState)
            })
        ])
        // Optimized Mesh menu
        let optimizedMeshMenu = UIMenu(title: "Optimized mesh...", children: [
            UIAction(title: "Colored Mesh", handler: { _ in
                self.exportMesh(isOBJ: false)
            }),
            UIAction(title: "Textured Mesh", handler: { _ in
                self.exportMesh(isOBJ: true)
            })
        ])
        
        // Export menu
        let exportMenu = UIMenu(title: "Assemble...", children: [pointCloudMenu, optimizedMeshMenu])
        
        // Optimized Mesh menu
        let optimizeAdvancedMenu = UIMenu(title: "Advanced...", children: [
            UIAction(title: "Global Graph Optimization", handler: { _ in
                self.optimization(approach: 0)
            }),
            UIAction(title: "Detect More Loop Closures", handler: { _ in
                self.optimization(approach: 2)
            }),
            UIAction(title: "Adjust Colors (Fast)", handler: { _ in
                self.optimization(approach: 5)
            }),
            UIAction(title: "Adjust Colors (Full)", handler: { _ in
                self.optimization(approach: 6)
            }),
            UIAction(title: "Mesh Smoothing", handler: { _ in
                self.optimization(approach: 7)
            }),
            UIAction(title: "Bundle Adjustment", handler: { _ in
                self.optimization(approach: 1)
            }),
            UIAction(title: "Noise Filtering", handler: { _ in
                self.optimization(approach: 4)
            })
        ])
        
        // Optimize menu
        let optimizeMenu = UIMenu(title: "Optimize...", children: [
            UIAction(title: "Standard Optimization", handler: { _ in
                self.optimization(approach: -1)
            }),
            optimizeAdvancedMenu])

        // Advanced menu
        let advancedMenu = UIMenu(title: "Advanced...", children: [
            UIAction(title: "New Data Recording", image: UIImage(systemName: "plus.app"), attributes: actionNewDataRecording ? [] : .disabled, state: .off, handler: { _ in
            	self.newScan(dataRecordingMode: true)
        	})
        ])
        
        // Measuring menu
        let measuringMenu = UIMenu(title: "Measuring...", image: UIImage(systemName: "ruler"), children: [
            UIAction(title: "Plane to Plane Mode", image: measuringMode == 0 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.measuringMode = 0
                self.rtabmap!.setMeasuringMode(self.measuringMode)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Point to Point Mode", image: measuringMode == 2 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.measuringMode = 2
                self.rtabmap!.setMeasuringMode(self.measuringMode)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Clear All Measures", image: UIImage(systemName: "trash"), state: .off, handler: { _ in
                self.clearMeasures();
                self.resetNoTouchTimer(true)
            })
        ])
                
        var fileMenuChildren: [UIMenuElement] = []
        fileMenuChildren.append(UIAction(title: "New Mapping Session", image: UIImage(systemName: "plus.app"), attributes: actionNewScanEnabled ? [] : .disabled, state: .off, handler: { _ in
            self.newScan()
        }))
        if(actionOptimizeEnabled) {
            fileMenuChildren.append(optimizeMenu)
        }
        else {
            fileMenuChildren.append(UIAction(title: "Optimize...", attributes: .disabled, state: .off, handler: { _ in
            }))
        }
        if(actionExportEnabled) {
            fileMenuChildren.append(exportMenu)
        }
        else {
            fileMenuChildren.append(UIAction(title: "Assemble...", attributes: .disabled, state: .off, handler: { _ in
            }))
        }
        fileMenuChildren.append(UIAction(title: "Save", image: UIImage(systemName: "square.and.arrow.down"), attributes: actionSaveEnabled ? [] : .disabled, state: .off, handler: { _ in
            self.save()
        }))
        fileMenuChildren.append(UIAction(title: "Append Scan", image: UIImage(systemName: "play.fill"), attributes: actionResumeEnabled ? [] : .disabled, state: .off, handler: { _ in
            self.resumeScan()
        }))
        if(actionMeasuringEnabled) {
            fileMenuChildren.append(measuringMenu)
        }
        else {
            fileMenuChildren.append(UIAction(title: "Measuring...", image: UIImage(systemName: "ruler"), attributes: .disabled, state: .off, handler: { _ in
            }))
        }
        fileMenuChildren.append(advancedMenu)
        
        // File menu
        let fileMenu = UIMenu(title: "File", options: .displayInline, children: fileMenuChildren)
        
        // Visibility menu
        let visibilityMenu = UIMenu(title: "Visibility...", children: [
            UIAction(title: "Status", image: statusShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState != .STATE_WELCOME) ? [] : .disabled, handler: { _ in
                self.statusShown = !self.statusShown
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Debug", image: debugShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState != .STATE_WELCOME) ? [] : .disabled, handler: { _ in
                self.debugShown = !self.debugShown
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Odom Visible", image: odomShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_MAPPING || self.mState == .STATE_CAMERA || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING) ? [] : .disabled, handler: { _ in
                self.odomShown = !self.odomShown
                self.rtabmap!.setOdomCloudShown(shown: self.odomShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Graph Visibile", image: graphShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_MAPPING || self.mState == .STATE_CAMERA || self.mState == .STATE_IDLE) ? [] : .disabled, handler: { _ in
                self.graphShown = !self.graphShown
                self.rtabmap!.setGraphVisible(visible: self.graphShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Grid Visible", image: gridShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.gridShown = !self.gridShown
                self.rtabmap!.setGridVisible(visible: self.gridShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Optimized Graph", image: optimizedGraphShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_IDLE) ? [] : .disabled, handler: { _ in
                self.optimizedGraphShown = !self.optimizedGraphShown
                self.rtabmap!.setGraphOptimization(enabled: self.optimizedGraphShown)
                self.resetNoTouchTimer(true)
            })
        ])
        
        let settingsMenu = UIMenu(title: "Settings", options: .displayInline, children: [visibilityMenu,
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape.2"), attributes: actionSettingsEnabled ? [] : .disabled, state: .off, handler: { _ in
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }

                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                        print("Settings opened: \(success)") // Prints true
                    })
                }
            }),
            UIAction(title: "Restore All Default Settings", attributes: actionSettingsEnabled ? [] : .disabled, state: .off, handler: { _ in
                
                let ac = UIAlertController(title: "Reset All Default Settings", message: "Do you want to reset all settings to default?", preferredStyle: .alert)
                ac.addAction(UIAlertAction(title: "Yes", style: .default, handler: { _ in
                    let notificationCenter = NotificationCenter.default
                    notificationCenter.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
                    UserDefaults.standard.reset()
                    self.registerSettingsBundle()
                    self.updateDisplayFromDefaults();
                    notificationCenter.addObserver(self, selector: #selector(self.defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
                }))
                ac.addAction(UIAlertAction(title: "No", style: .cancel, handler: nil))
                self.present(ac, animated: true)
             })
        ])

        menuButton.menu = UIMenu(title: "", children: [fileMenu, settingsMenu])
        menuButton.addTarget(self, action: #selector(ViewController.menuOpened(_:)), for: .menuActionTriggered)
        
        // Camera menu
        let renderingMenu = UIMenu(title: "Rendering", options: .displayInline, children: [
            UIAction(title: "Texture/Color Blend", image: self.textureColorSeamsShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: self.mState == .STATE_VISUALIZING || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING || self.mState == .STATE_VISUALIZING_WHILE_LOADING ? [] : .disabled, handler: { _ in
                self.textureColorSeamsShown = !self.textureColorSeamsShown
                self.rtabmap!.setTextureColorSeamsHidden(hidden: !self.textureColorSeamsShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Wireframe", image: self.wireframeShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.wireframeShown = !self.wireframeShown
                self.rtabmap!.setWireframe(enabled: self.wireframeShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Lighting", image: self.lightingShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: self.mState == .STATE_VISUALIZING || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING || self.mState == .STATE_VISUALIZING_WHILE_LOADING ? [] : .disabled, handler: { _ in
                self.lightingShown = !self.lightingShown
                self.rtabmap!.setLighting(enabled: self.lightingShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Backface", image: self.backfaceShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.backfaceShown = !self.backfaceShown
                self.rtabmap!.setBackfaceCulling(enabled: !self.backfaceShown)
                self.resetNoTouchTimer(true)
            })
        ])
        
        let cameraMenu = UIMenu(title: "View", options: .displayInline, children: [
            UIAction(title: "First-P. View", image: cameraMode == 0 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_CAMERA || self.mState == .STATE_VISUALIZING || self.mState == .STATE_MAPPING || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING) ? [] : .disabled, handler: { _ in
                self.setGLCamera(type: 0)
                if(self.mState == .STATE_VISUALIZING)
                {
                    self.rtabmap?.setLocalizationMode(enabled: true)
                    self.rtabmap?.setPausedMapping(paused: false);
                    self.updateState(state: .STATE_VISUALIZING_CAMERA)
                    self.startCamera()
                }
                else
                {
                    self.resetNoTouchTimer(true)
                }
            }),
            UIAction(title: "Third-P. View", image: cameraMode == 1 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState != .STATE_VISUALIZING_AND_MEASURING) ? [] : .disabled, handler: { _ in
                self.setGLCamera(type: 1)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Top View", image: cameraMode == 2 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.setGLCamera(type: 2)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Ortho View", image: cameraMode == 3 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.setGLCamera(type: 3)
                self.resetNoTouchTimer(true)
            })
        ])
        
        let showCloudMeshActions = mState != .STATE_VISUALIZING && mState != .STATE_VISUALIZING_CAMERA && mState != .STATE_VISUALIZING_AND_MEASURING && mState != .STATE_PROCESSING && mState != .STATE_VISUALIZING_WHILE_LOADING
        let cloudMeshMenu = UIMenu(title: "CloudMesh", options: .displayInline, children: [
            UIAction(title: "Point Cloud", image: viewMode == 0 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: showCloudMeshActions ? [] : .disabled, handler: { _ in
                self.setMeshRendering(viewMode: 0)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Mesh", image: viewMode == 1 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: showCloudMeshActions ? [] : .disabled, handler: { _ in
                self.setMeshRendering(viewMode: 1)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Texture Mesh", image: viewMode == 2 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: showCloudMeshActions ? [] : .disabled, handler: { _ in
                self.setMeshRendering(viewMode: 2)
                self.resetNoTouchTimer(true)
            })
        ])

        var viewMenuChildren: [UIMenuElement] = []
        viewMenuChildren.append(cameraMenu)
        viewMenuChildren.append(renderingMenu)
        viewMenuChildren.append(cloudMeshMenu)
        viewButton.menu = UIMenu(title: "", children: viewMenuChildren)
        viewButton.addTarget(self, action: #selector(ViewController.menuOpened(_:)), for: .menuActionTriggered)
    }
    
    @IBAction func menuOpened(_ sender:UIButton)
    {
        mMenuOpened = true;
    }
    
    func exportMesh(isOBJ: Bool)
    {
        let ac = UIAlertController(title: "Maximum Polygons", message: "\n\n\n\n\n\n\n\n\n\n", preferredStyle: .alert)
        ac.view.addSubview(maxPolygonsPickerView)
        maxPolygonsPickerView.selectRow(2, inComponent: 0, animated: false)
        ac.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            let pickerValue = self.maxPolygonsPickerData[self.maxPolygonsPickerView.selectedRow(inComponent: 0)]
            self.export(isOBJ: isOBJ, meshing: true, regenerateCloud: false, optimized: true, optimizedMaxPolygons: pickerValue*100000, previousState: self.mState);
        }))
        ac.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        present(ac, animated: true)
    }
    
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return maxPolygonsPickerData.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if(row == 0)
        {
            return "No Limit"
        }
        return "\(maxPolygonsPickerData[row])00 000"
    }
    
    // Auto-hide the home indicator to maximize immersion in AR experiences.
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    // Hide the status bar to maximize immersion in AR experiences.
    override var prefersStatusBarHidden: Bool {
        return !mHudVisible
    }

    //This is called when a new frame has been updated.
    func session(_ session: ARSession, didUpdate frame: ARFrame)
    {
        let started = CACurrentMediaTime()
        var status = ""
        var accept = false
        
        switch frame.camera.trackingState {
        case .normal:
            accept = true
        case .notAvailable:
            status = "Tracking not available"
        case .limited(.excessiveMotion):
            accept = true
            status = "Please Slow Your Movement"
        case .limited(.insufficientFeatures):
            accept = true
            status = "Avoid Featureless Surfaces"
        case .limited(.initializing):
            status = "Initializing"
        case .limited(.relocalizing):
            status = "Relocalizing"
        default:
            status = "Unknown tracking state"
        }
        
        mLastLightEstimate = frame.lightEstimate?.ambientIntensity
        
        if !status.isEmpty && mLastLightEstimate != nil && mLastLightEstimate! < 100 && accept {
            status = "Camera Is Occluded Or Lighting Is Too Dark"
        }

        if let rotation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        {
            rtabmap?.postOdometryEvent(frame: frame, orientation: rotation, viewport: self.view.frame.size)
        }
        scanRecorder.process(frame: frame, session: session, processingTime: CACurrentMediaTime() - started)

        if !status.isEmpty {
            DispatchQueue.main.async {
                self.showToast(message: status, seconds: 2)
            }
        }
    }
    
    // This is called when a session fails.
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user.
        guard error is ARError else { return }
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        scanRecorder.event("ar_virhe", errorMessage)
        DispatchQueue.main.async {
            // Present an alert informing about the error that has occurred.
            let alertController = UIAlertController(title: "The AR session failed.", message: errorMessage, preferredStyle: .alert)
            let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
                alertController.dismiss(animated: true, completion: nil)
                if let configuration = self.session.configuration {
                    self.session.run(configuration, options: [.resetSceneReconstruction, .resetTracking, .removeExistingAnchors])
                }
            }
            alertController.addAction(restartAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        scanRecorder.event("ar_keskeytys", "AR session interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        scanRecorder.event("ar_keskeytys", "AR session interruption ended")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    {
        mLastKnownLocation = locations.last!
        rtabmap?.setGPS(location: locations.last!);
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error)
    {
        print(error)
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus)
    {
        print(status.rawValue)
        if(status == .notDetermined)
        {
            locationManager?.requestWhenInUseAuthorization()
        }
        if(status == .denied)
        {
            let alertController = UIAlertController(title: "GPS Disabled", message: "GPS option is enabled (Settings->Mapping...) but localization is denied for this App. To enable location for this App, go in Settings->Privacy->Location.", preferredStyle: .alert)

            let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
                self.locationManager = nil
                self.mLastKnownLocation = nil
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }

                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                        print("Settings opened: \(success)") // Prints true
                    })
                }
            }
            alertController.addAction(settingsAction)
            
            let okAction = UIAlertAction(title: "Turn Off GPS", style: .default) { (action) in
                UserDefaults.standard.setValue(false, forKey: "SaveGPS")
                self.updateDisplayFromDefaults()
            }
            alertController.addAction(okAction)
            
            present(alertController, animated: true)
        }
        else if(status == .authorizedWhenInUse)
        {
            if locationManager != nil {
                if(locationManager!.accuracyAuthorization == .reducedAccuracy) {
                    let alertController = UIAlertController(title: "GPS Reduced Accuracy", message: "Your location settings for this App is set to reduced accuracy. We recommend to use high accuracy.", preferredStyle: .alert)

                    let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
                        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                            return
                        }

                        if UIApplication.shared.canOpenURL(settingsUrl) {
                            UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                                print("Settings opened: \(success)") // Prints true
                            })
                        }
                    }
                    alertController.addAction(settingsAction)
                    
                    let okAction = UIAlertAction(title: "Ignore", style: .default) { (action) in
                    }
                    alertController.addAction(okAction)
                    
                    present(alertController, animated: true)
                }
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // The screen shouldn't dim during AR experiences.
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    var statusBarOrientation: UIInterfaceOrientation? {
        get {
            guard let orientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation else {
                #if DEBUG
                fatalError("Could not obtain UIInterfaceOrientation from a valid windowScene")
                #else
                return nil
                #endif
            }
            return orientation
        }
    }
        
    deinit {
        EAGLContext.setCurrent(context)
        rtabmap = nil
        context = nil
        EAGLContext.setCurrent(nil)
    }
    
    var firstTouch: UITouch?
    var secondTouch: UITouch?
    
    override func touchesBegan(_ touches: Set<UITouch>,
                 with event: UIEvent?)
    {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            if (firstTouch == nil) {
                firstTouch = touch
                let pose = touch.location(in: self.view)
                let normalizedX = pose.x / self.view.bounds.size.width;
                let normalizedY = pose.y / self.view.bounds.size.height;
                rtabmap?.onTouchEvent(touch_count: 1, event: 0, x0: Float(normalizedX), y0: Float(normalizedY), x1: 0.0, y1: 0.0);
            }
            else if (firstTouch != nil && secondTouch == nil)
            {
                secondTouch = touch
                if let pose0 = firstTouch?.location(in: self.view)
                {
                    if let pose1 = secondTouch?.location(in: self.view)
                    {
                        let normalizedX0 = pose0.x / self.view.bounds.size.width;
                        let normalizedY0 = pose0.y / self.view.bounds.size.height;
                        let normalizedX1 = pose1.x / self.view.bounds.size.width;
                        let normalizedY1 = pose1.y / self.view.bounds.size.height;
                        rtabmap?.onTouchEvent(touch_count: 2, event: 5, x0: Float(normalizedX0), y0: Float(normalizedY0), x1: Float(normalizedX1), y1: Float(normalizedY1));
                    }
                }
            }
        }
        if self.isPaused {
            self.view.setNeedsDisplay()
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        var firstTouchUsed = false
        var secondTouchUsed = false
        for touch in touches {
            if(touch == firstTouch)
            {
                firstTouchUsed = true
            }
            else if(touch == secondTouch)
            {
                secondTouchUsed = true
            }
        }
        if(secondTouch != nil)
        {
            if(firstTouchUsed || secondTouchUsed)
            {
                if let pose0 = firstTouch?.location(in: self.view)
                {
                    if let pose1 = secondTouch?.location(in: self.view)
                    {
                        let normalizedX0 = pose0.x / self.view.bounds.size.width;
                        let normalizedY0 = pose0.y / self.view.bounds.size.height;
                        let normalizedX1 = pose1.x / self.view.bounds.size.width;
                        let normalizedY1 = pose1.y / self.view.bounds.size.height;
                        rtabmap?.onTouchEvent(touch_count: 2, event: 2, x0: Float(normalizedX0), y0: Float(normalizedY0), x1: Float(normalizedX1), y1: Float(normalizedY1));
                    }
                }
            }
        }
        else if(firstTouchUsed)
        {
            if let pose = firstTouch?.location(in: self.view)
            {
                let normalizedX = pose.x / self.view.bounds.size.width;
                let normalizedY = pose.y / self.view.bounds.size.height;
                rtabmap?.onTouchEvent(touch_count: 1, event: 2, x0: Float(normalizedX), y0: Float(normalizedY), x1: 0.0, y1: 0.0);
            }
        }
        if self.isPaused {
            self.view.setNeedsDisplay()
        }
    }

    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        for touch in touches {
            if(touch == firstTouch)
            {
                firstTouch = nil
            }
            else if(touch == secondTouch)
            {
                secondTouch = nil
            }
        }
        if (firstTouch == nil && secondTouch != nil)
        {
            firstTouch = secondTouch
            secondTouch = nil
        }
        if (firstTouch != nil && secondTouch == nil)
        {
            let pose = firstTouch!.location(in: self.view)
            let normalizedX = pose.x / self.view.bounds.size.width;
            let normalizedY = pose.y / self.view.bounds.size.height;
            rtabmap?.onTouchEvent(touch_count: 1, event: 0, x0: Float(normalizedX), y0: Float(normalizedY), x1: 0.0, y1: 0.0);
        }
        if self.isPaused {
            self.view.setNeedsDisplay()
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        for touch in touches {
            if(touch == firstTouch)
            {
                firstTouch = nil;
            }
            else if(touch == secondTouch)
            {
                secondTouch = nil;
            }
        }
        if self.isPaused {
            self.view.setNeedsDisplay()
        }
    }
    
    @IBAction func doubleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == UIGestureRecognizer.State.recognized
        {
            let pose = gestureRecognizer.location(in: gestureRecognizer.view)
            let normalizedX = pose.x / self.view.bounds.size.width;
            let normalizedY = pose.y / self.view.bounds.size.height;
            rtabmap?.onTouchEvent(touch_count: 3, event: 0, x0: Float(normalizedX), y0: Float(normalizedY), x1: 0.0, y1: 0.0);
        
            
            if self.isPaused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.view.setNeedsDisplay()
                }
            }
        }
    }
    
    @IBAction func singleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .recognized
        {
            resetNoTouchTimer(!mHudVisible)
            
            if self.isPaused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.view.setNeedsDisplay()
                }
            }
        }
    }
    
    func registerSettingsBundle(){
        let appDefaults = [String:AnyObject]()
        UserDefaults.standard.register(defaults: appDefaults)
    }
    
    func updateDisplayFromDefaults()
    {
        //Get the defaults
        let defaults = UserDefaults.standard
 
        //let appendMode = defaults.bool(forKey: "AppendMode")
        
        // update preference
        rtabmap!.setOnlineBlending(enabled: defaults.bool(forKey: "Blending"));
        rtabmap!.setNodesFiltering(enabled: defaults.bool(forKey: "NodesFiltering"));
        rtabmap!.setFullResolution(enabled: defaults.bool(forKey: "HDMode"));
        rtabmap!.setSmoothing(enabled: defaults.bool(forKey: "Smoothing"));
        rtabmap!.setDepthBleedingError(value: defaults.float(forKey: "DepthBleedingError"));
        rtabmap!.setAppendMode(enabled: defaults.bool(forKey: "AppendMode"));
        rtabmap!.setUpstreamRelocalizationAccThr(value: defaults.float(forKey: "UpstreamRelocalizationFilteringAccThr"));
        rtabmap!.setExportPointCloudFormat(format: defaults.string(forKey: "ExportPointCloudFormat")!);
        
        mTimeThr = (defaults.string(forKey: "TimeLimit")! as NSString).integerValue
        mMaxFeatures = (defaults.string(forKey: "MaxFeaturesExtractedLoopClosure")! as NSString).integerValue
        
        // Mapping parameters
        rtabmap!.setMappingParameter(key: "Rtabmap/DetectionRate", value: defaults.string(forKey: "UpdateRate")!);
        rtabmap!.setMappingParameter(key: "Rtabmap/TimeThr", value: defaults.string(forKey: "TimeLimit")!);
        rtabmap!.setMappingParameter(key: "Rtabmap/MemoryThr", value: defaults.string(forKey: "MemoryLimit")!);
        rtabmap!.setMappingParameter(key: "RGBD/LinearSpeedUpdate", value: defaults.string(forKey: "MaximumMotionSpeed")!);
        let motionSpeed = ((defaults.string(forKey: "MaximumMotionSpeed")!) as NSString).floatValue/2.0;
        rtabmap!.setMappingParameter(key: "RGBD/AngularSpeedUpdate", value: NSString(format: "%.2f", motionSpeed) as String);
        rtabmap!.setMappingParameter(key: "Rtabmap/LoopThr", value: defaults.string(forKey: "LoopClosureThreshold")!);
        rtabmap!.setMappingParameter(key: "Mem/RehearsalSimilarity", value: defaults.string(forKey: "SimilarityThreshold")!);
        rtabmap!.setMappingParameter(key: "Kp/MaxFeatures", value: defaults.string(forKey: "MaxFeaturesExtractedVocabulary")!);
        rtabmap!.setMappingParameter(key: "Vis/MaxFeatures", value: defaults.string(forKey: "MaxFeaturesExtractedLoopClosure")!);
        rtabmap!.setMappingParameter(key: "Vis/MinInliers", value: defaults.string(forKey: "MinInliers")!);
        rtabmap!.setMappingParameter(key: "RGBD/OptimizeMaxError", value: defaults.string(forKey: "MaxOptimizationError")!);
        rtabmap!.setMappingParameter(key: "Kp/DetectorStrategy", value: defaults.string(forKey: "FeatureType")!);
        rtabmap!.setMappingParameter(key: "Vis/FeatureType", value: defaults.string(forKey: "FeatureType")!);
        rtabmap!.setMappingParameter(key: "Mem/NotLinkedNodesKept", value: defaults.bool(forKey: "SaveAllFramesInDatabase") ? "true" : "false");
        rtabmap!.setMappingParameter(key: "RGBD/OptimizeFromGraphEnd", value: defaults.bool(forKey: "OptimizationfromGraphEnd") ? "true" : "false");
        rtabmap!.setMappingParameter(key: "RGBD/MaxOdomCacheSize", value: defaults.string(forKey: "MaximumOdometryCacheSize")!);
        rtabmap!.setMappingParameter(key: "Optimizer/Strategy", value: defaults.string(forKey: "GraphOptimizer")!);
        rtabmap!.setMappingParameter(key: "RGBD/ProximityBySpace", value: defaults.string(forKey: "ProximityDetection")!);

        let markerDetection = defaults.integer(forKey: "ArUcoMarkerDetection")
        if(markerDetection == -1)
        {
            rtabmap!.setMappingParameter(key: "RGBD/MarkerDetection", value: "false");
        }
        else
        {
            rtabmap!.setMappingParameter(key: "RGBD/MarkerDetection", value: "true");
            rtabmap!.setMappingParameter(key: "Marker/Dictionary", value: defaults.string(forKey: "ArUcoMarkerDetection")!);
            rtabmap!.setMappingParameter(key: "Marker/CornerRefinementMethod", value: (markerDetection > 16 ? "3":"0"));
            rtabmap!.setMappingParameter(key: "Marker/MaxDepthError", value: defaults.string(forKey: "MarkerDepthErrorEstimation")!);
            rtabmap!.setMappingParameter(key: "Marker/MaxRange", value: defaults.string(forKey: "MarkerMaxRange")!);
            // Whole millimetres, so the region's decimal separator cannot matter (with "15.4" cm and a decimal comma the size fell back to 0)
            let markerSize = (defaults.string(forKey: "MarkerSize") ?? "").trimmingCharacters(in: .whitespaces)
            // 1-49 mm is most likely an old value in centimetres (e.g. 16), which would make the markers 10x too small
            if let mm = Int(markerSize), mm <= 0 || mm >= 50
            {
                rtabmap!.setMappingParameter(key: "Marker/Length", value: String(format: "%f", Double(mm)/1000.0))
            }
            else{
                rtabmap!.setMappingParameter(key: "Marker/Length", value: "0")
                DispatchQueue.main.async {
                    self.showToast(message: "Marker Size \"\(markerSize)\" is not whole millimetres of at least 50 (e.g. 154), using 0.", seconds: 5)
                }
            }
        }

        // Rendering
        rtabmap!.setCloudDensityLevel(value: defaults.integer(forKey: "PointCloudDensity"));
        rtabmap!.setMaxCloudDepth(value: defaults.float(forKey: "MaxDepth"));
        rtabmap!.setMinCloudDepth(value: defaults.float(forKey: "MinDepth"));
        rtabmap!.setDepthConfidence(value: defaults.integer(forKey: "DepthConfidence"));
        rtabmap!.setPointSize(value: defaults.float(forKey: "PointSize"));
        rtabmap!.setMeshAngleTolerance(value: defaults.float(forKey: "MeshAngleTolerance"));
        rtabmap!.setMeshTriangleSize(value: defaults.integer(forKey: "MeshTriangleSize"));
        rtabmap!.setMeshDecimationFactor(value: defaults.float(forKey: "MeshDecimationFactor"));
        let bgColor = defaults.float(forKey: "BackgroundColor");
        rtabmap!.setBackgroundColor(gray: bgColor);
        
        DispatchQueue.main.async {
            self.statusLabel.textColor = bgColor>=0.6 ? UIColor(white: 0.0, alpha: 1) : UIColor(white: 1.0, alpha: 1)
        }
    
        rtabmap!.setClusterRatio(value: defaults.float(forKey: "NoiseFilteringRatio"));
        rtabmap!.setMaxGainRadius(value: defaults.float(forKey: "ColorCorrectionRadius"));
        rtabmap!.setRenderingTextureDecimation(value: defaults.integer(forKey: "TextureResolution"));
        
        rtabmap!.setMetricSystem(defaults.integer(forKey: "MeasuringUnits") == 0);
        rtabmap!.setMeasuringTextSize(defaults.float(forKey: "MeasuringTextSize"));
        
        if(locationManager != nil && !defaults.bool(forKey: "SaveGPS"))
        {
            locationManager?.stopUpdatingLocation()
            locationManager = nil
            mLastKnownLocation = nil
        }
        else if(locationManager == nil && defaults.bool(forKey: "SaveGPS"))
        {
            locationManager = CLLocationManager()
            locationManager?.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            locationManager?.delegate = self
        }
    }
    
    func resumeScan()
    {
        if(mState == State.STATE_VISUALIZING)
        {
            closeVisualization()
            rtabmap!.postExportation(visualize: false)
        }
        
        if(!mDataRecording) {
            let alertController = UIAlertController(title: "Append Mode", message: "The camera preview will not be aligned to map on start, move to a previously scanned area, then push Record. When a loop closure is detected, new scans will be appended to map.", preferredStyle: .alert)
            
            let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
            }
            alertController.addAction(okAction)
            
            present(alertController, animated: true)
        }
        
        setGLCamera(type: 0);
        startCamera();
    }
    
    func newScan(dataRecordingMode: Bool = false)
    {
        print("databases.size() = \(databases.size())")
        if(databases.count >= 10 && !mReviewRequested && self.depthSupported)
        {
            SKStoreReviewController.requestReviewInCurrentScene()
            mReviewRequested = true
        }
        
        if(mState == State.STATE_VISUALIZING)
        {
            closeVisualization()
        }
        
        mMapNodes = 0;
        self.openedDatabasePath = nil
        let tmpDatabase = self.getDocumentDirectory().appendingPathComponent(self.RTABMAP_TMP_DB)
        if(!(self.mState == State.STATE_CAMERA || self.mState == State.STATE_MAPPING) &&
           FileManager.default.fileExists(atPath: tmpDatabase.path) &&
           tmpDatabase.fileSize > 1024*1024) // > 1MB
        {
            dismiss(animated: true, completion: {
                let msg = "The previous session (\(tmpDatabase.fileSizeString)) was not correctly saved, do you want to recover it?"
                let alert = UIAlertController(title: "Recovery", message: msg, preferredStyle: .alert)
                let alertActionNo = UIAlertAction(title: "Ignore", style: .destructive) {
                    (UIAlertAction) -> Void in
                    do {
                        try FileManager.default.removeItem(at: tmpDatabase)
                    }
                    catch {
                        print("Could not clear tmp database: \(error)")
                    }
                    self.newScan(dataRecordingMode: dataRecordingMode)
                }
                alert.addAction(alertActionNo)
                let alertActionCancel = UIAlertAction(title: "Cancel", style: .cancel) {
                    (UIAlertAction) -> Void in
                    // do nothing
                }
                alert.addAction(alertActionCancel)
                let alertActionYes = UIAlertAction(title: "Yes", style: .default) {
                    (UIAlertAction2) -> Void in

                    let fileName = Date().getFormattedDate(format: "yyMMdd-HHmmss") + ".db"
                    let outputDbPath = self.getDocumentDirectory().appendingPathComponent(fileName).path
                    
                    var indicator: UIActivityIndicatorView?
                    
                    let alertView = UIAlertController(title: "Recovering", message: "Please wait while recovering data...", preferredStyle: .alert)
                    let alertViewActionCancel = UIAlertAction(title: "Cancel", style: .cancel) {
                        (UIAlertAction) -> Void in
                        self.dismiss(animated: true, completion: {
                            self.progressView = nil
                            
                            indicator = UIActivityIndicatorView(style: .large)
                            indicator?.frame = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 60.0)
                            indicator?.center = self.view.center
                            self.view.addSubview(indicator!)
                            indicator?.bringSubviewToFront(self.view)
                            
                            indicator?.startAnimating()
                            self.rtabmap!.cancelProcessing();
                        })
                    }
                    alertView.addAction(alertViewActionCancel)
                    
                    let previousState = self.mState
                    self.updateState(state: .STATE_PROCESSING);
                    
                    self.present(alertView, animated: true, completion: {
                        //  Add your progressbar after alert is shown (and measured)
                        let margin:CGFloat = 8.0
                        let rect = CGRect(x: margin, y: 84.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
                        self.progressView = UIProgressView(frame: rect)
                        self.progressView!.progress = 0
                        self.progressView!.tintColor = self.view.tintColor
                        alertView.view.addSubview(self.progressView!)
                        
                        var success : Bool = false
                        DispatchQueue.background(background: {
                            
                            success = self.rtabmap!.recover(from: tmpDatabase.path, to: outputDbPath)
                            
                        }, completion:{
                            if(indicator != nil)
                            {
                                indicator!.stopAnimating()
                                indicator!.removeFromSuperview()
                            }
                            if self.progressView != nil
                            {
                                self.dismiss(animated: self.openedDatabasePath == nil, completion: {
                                    if(success)
                                    {
                                        let alertSaved = UIAlertController(title: "Database saved!", message: String(format: "Database \"%@\" successfully recovered!", fileName), preferredStyle: .alert)
                                        let yes = UIAlertAction(title: "OK", style: .default) {
                                            (UIAlertAction) -> Void in
                                            self.openDatabase(fileUrl: URL(fileURLWithPath: outputDbPath))
                                        }
                                        alertSaved.addAction(yes)
                                        self.present(alertSaved, animated: true, completion: nil)
                                    }
                                    else
                                    {
                                        self.updateState(state: previousState);
                                        self.showToast(message: "Recovery failed!", seconds: 4)
                                    }
                                })
                            }
                            else
                            {
                                self.showToast(message: "Recovery canceled", seconds: 2)
                                self.updateState(state: previousState);
                            }
                        })
                    })
                }
                alert.addAction(alertActionYes)
                self.present(alert, animated: true, completion: nil)
            })
        }
        else
        {
            let inMemory = UserDefaults.standard.bool(forKey: "DatabaseInMemory") && !dataRecordingMode
            mDataRecording = dataRecordingMode
            self.rtabmap!.setDataRecorderMode(enabled: dataRecordingMode)
            self.optimizedGraphShown = true // Always reset to true when opening a database
            self.rtabmap!.openDatabase(databasePath: tmpDatabase.path, databaseInMemory: inMemory, optimize: false, clearDatabase: true)
            self.scanRecorder.reset()
            
            if(!(self.mState == State.STATE_CAMERA || self.mState == State.STATE_MAPPING))
            {
                if(mDataRecording) {
                    let alertController = UIAlertController(title: "Data Recording Mode", message: "This mode should be only used if you want to record raw ARKit data as long as possible without any feedback: loop closure detection and map rendering are disabled. The database size in Debug display shows how much data has been recorded so far.", preferredStyle: .alert)
                    
                    let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
                    }
                    alertController.addAction(okAction)
                    
                    present(alertController, animated: true)
                    self.debugShown = true
                }
                
                self.setGLCamera(type: 0);
                self.startCamera();
            }
        }
    }
    
    func save()
    {
        //Step : 1
        let alert = UIAlertController(title: "Save Scan", message: "RTAB-Map Database Name (*.db):", preferredStyle: .alert )
        //Step : 2
        let save = UIAlertAction(title: "Save", style: .default) { (alertAction) in
            let textField = alert.textFields![0] as UITextField
            if textField.text != "" {
                //Read TextFields text data
                let fileName = textField.text!+".db"
                let filePath = self.getDocumentDirectory().appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: filePath) {
                    let alert = UIAlertController(title: "File Already Exists", message: "Do you want to overwrite the existing file?", preferredStyle: .alert)
                    let yes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        self.saveDatabase(fileName: fileName);
                    }
                    alert.addAction(yes)
                    let no = UIAlertAction(title: "No", style: .cancel) {
                        (UIAlertAction) -> Void in
                        if(self.mDataRecording) {
                            self.save() // We cannot skip saving after data recording
                        }
                    }
                    alert.addAction(no)
                    
                    self.present(alert, animated: true, completion: nil)
                } else {
                    self.saveDatabase(fileName: fileName);
                }
            }
            else
            {
                self.save()
            }
        }

        //Step : 3
        var placeholder = Date().getFormattedDate(format: "yyMMdd-HHmmss")
        if(mDataRecording) {
            placeholder += "-recording"
        }
        if self.openedDatabasePath != nil && !self.openedDatabasePath!.path.isEmpty
        {
            var components = self.openedDatabasePath!.lastPathComponent.components(separatedBy: ".")
            if components.count > 1 { // If there is a file extension
                components.removeLast()
                placeholder = components.joined(separator: ".")
            } else {
                placeholder = self.openedDatabasePath!.lastPathComponent
            }
        }
        alert.addTextField { (textField) in
                textField.text = placeholder
        }

        //Step : 4
        alert.addAction(save)
        //Cancel action
        if(!mDataRecording) {
            alert.addAction(UIAlertAction(title: "Cancel", style: .default) { (alertAction) in })
        }

        self.present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }
    
    func saveDatabase(fileName: String)
    {
        let filePath = self.getDocumentDirectory().appendingPathComponent(fileName).path
        
        let indicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .large)
        indicator.frame = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 60.0)
        indicator.center = view.center
        view.addSubview(indicator)
        indicator.bringSubviewToFront(view)
        
        indicator.startAnimating()
        
        let previousState = mState;
        updateState(state: .STATE_PROCESSING);
        
        DispatchQueue.background(background: {
            self.rtabmap?.save(databasePath: filePath); // save
        }, completion:{
            // main thread
            indicator.stopAnimating()
            indicator.removeFromSuperview()
            
            self.openedDatabasePath = URL(fileURLWithPath: filePath)
            
            let alert = UIAlertController(title: "Database saved!", message: String(format: "Database \"%@\" successfully saved! The zip is being packed as %@-kesken.zip and is ready when it is renamed %@.zip in Files.", fileName, (fileName as NSString).deletingPathExtension, (fileName as NSString).deletingPathExtension), preferredStyle: .alert)
            let yes = UIAlertAction(title: "OK", style: .default) {
                (UIAlertAction) -> Void in
            }
            alert.addAction(yes)
            self.present(alert, animated: true, completion: nil)
            do {
                let tmpDatabase = self.getDocumentDirectory().appendingPathComponent(self.RTABMAP_TMP_DB)
                try FileManager.default.removeItem(at: tmpDatabase)
            }
            catch {
                print("Could not clear tmp database: \(error)")
            }
            self.updateDatabases()
            self.updateState(state: self.mDataRecording ? .STATE_WELCOME : previousState)
            self.scanRecorder.package(database: URL(fileURLWithPath: filePath))
        })
    }
    
    private func export(isOBJ: Bool, meshing: Bool, regenerateCloud: Bool, optimized: Bool, optimizedMaxPolygons: Int, previousState: State)
    {
        let defaults = UserDefaults.standard
        let cloudVoxelSize = defaults.float(forKey: "VoxelSize")
        let textureSize = isOBJ ? defaults.integer(forKey: "TextureSize") : 0
        let textureCount = defaults.integer(forKey: "MaximumOutputTextures")
        let normalK = defaults.integer(forKey: "NormalK")
        let maxTextureDistance = defaults.float(forKey: "MaxTextureDistance")
        let minTextureClusterSize = defaults.integer(forKey: "MinTextureClusterSize")
        let optimizedVoxelSize = cloudVoxelSize
        let optimizedDepth = defaults.integer(forKey: "ReconstructionDepth")
        let optimizedColorRadius = defaults.float(forKey: "ColorRadius")
        let optimizedCleanWhitePolygons = defaults.bool(forKey: "CleanMesh")
        let optimizedMinClusterSize = defaults.integer(forKey: "PolygonFiltering")
        let textureVertexColorPolicy = defaults.integer(forKey: "TextureVertexColorPolicy")
        let blockRendering = false
        
        var indicator: UIActivityIndicatorView?
        
        let alertView = UIAlertController(title: "Assembling", message: "Please wait while assembling data...", preferredStyle: .alert)
        alertView.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: {
                self.progressView = nil
                
                indicator = UIActivityIndicatorView(style: .large)
                indicator?.frame = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 60.0)
                indicator?.center = self.view.center
                self.view.addSubview(indicator!)
                indicator?.bringSubviewToFront(self.view)
                
                indicator?.startAnimating()
                
                self.rtabmap!.cancelProcessing()
            })
            
        }))
	
        let previousState = mState
        
        updateState(state: .STATE_PROCESSING);
        
        present(alertView, animated: true, completion: {
            //  Add your progressbar after alert is shown (and measured)
            let margin:CGFloat = 8.0
            let rect = CGRect(x: margin, y: 84.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
            self.progressView = UIProgressView(frame: rect)
            self.progressView!.progress = 0
            self.progressView!.tintColor = self.view.tintColor
            alertView.view.addSubview(self.progressView!)
            
            self.progressStatusUpdate() // This will update memory usage during post processing
            
            var success : Bool = false
            DispatchQueue.background(background: {
                
                success = self.rtabmap!.exportMesh(
                    cloudVoxelSize: cloudVoxelSize,
                    regenerateCloud: regenerateCloud,
                    meshing: meshing,
                    textureSize: textureSize,
                    textureCount: textureCount,
                    normalK: normalK,
                    optimized: optimized,
                    optimizedVoxelSize: optimizedVoxelSize,
                    optimizedDepth: optimizedDepth,
                    optimizedMaxPolygons: optimizedMaxPolygons,
                    optimizedColorRadius: optimizedColorRadius,
                    optimizedCleanWhitePolygons: optimizedCleanWhitePolygons,
                    optimizedMinClusterSize: optimizedMinClusterSize,
                    optimizedMaxTextureDistance: maxTextureDistance,
                    optimizedMinTextureClusterSize: minTextureClusterSize,
                    textureVertexColorPolicy: textureVertexColorPolicy,
                    blockRendering: blockRendering)
                
            }, completion:{
                if(indicator != nil)
                {
                    indicator!.stopAnimating()
                    indicator!.removeFromSuperview()
                }
                if self.progressView != nil
                {
                    self.dismiss(animated: self.openedDatabasePath == nil, completion: {
                        if(success)
                        {
                            if(!meshing && cloudVoxelSize>0.0)
                            {
                                self.showToast(message: "Cloud assembled and voxelized at \(cloudVoxelSize) m.", seconds: 2)
                            }
                            
                            if(!meshing)
                            {
                                self.visualizationType = 0;
                                self.setMeshRendering(viewMode: 0)
                            }
                            else if(!isOBJ)
                            {
                                self.visualizationType = 1;
                                self.setMeshRendering(viewMode: 1)
                            }
                            else // isOBJ
                            {
                                self.visualizationType = 2;
                                self.setMeshRendering(viewMode: 2)
                            }

                            self.updateState(state: .STATE_VISUALIZING)
                            
                            self.rtabmap!.postExportation(visualize: true)
							
                            if previousState != .STATE_VISUALIZING
                            {
                                self.setGLCamera(type: 2)
                            }

                            if self.openedDatabasePath == nil
                            {
                                self.save();
                            }
                        }
                        else
                        {
                            self.updateState(state: previousState);
                            self.showToast(message: "Exporting map failed!", seconds: 4)
                        }
                    })
                }
                else
                {
                    self.showToast(message: "Export canceled", seconds: 2)
                    self.updateState(state: previousState);
                }
            })
        })
    }
    
    private func optimization(withStandardMeshExport: Bool = false, approach: Int)
    {
        if(mState == State.STATE_VISUALIZING)
        {
            closeVisualization()
            rtabmap!.postExportation(visualize: false)
        }
        
        let alertView = UIAlertController(title: "Post-Processing", message: "Please wait while optimizing...", preferredStyle: .alert)
        alertView.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.dismiss(animated: true)
            self.progressView = nil
            self.rtabmap!.cancelProcessing()
        }))

        let previousState = mState
        
        updateState(state: .STATE_PROCESSING)
        
        //  Show it to your users
        present(alertView, animated: true, completion: {
            //  Add your progressbar after alert is shown (and measured)
            let margin:CGFloat = 8.0
            let rect = CGRect(x: margin, y: 72.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
            self.progressView = UIProgressView(frame: rect)
            self.progressView!.progress = 0
            self.progressView!.tintColor = self.view.tintColor
            alertView.view.addSubview(self.progressView!)
            
            self.progressStatusUpdate() // This will update memory usage during post processing
            
            var loopDetected : Int = -1
            DispatchQueue.background(background: {
                loopDetected = self.rtabmap!.postProcessing(approach: approach);
            }, completion:{
                // main thread
                if self.progressView != nil
                {
                    self.dismiss(animated: self.openedDatabasePath == nil, completion: {
                        self.progressView = nil
                        
                        if(loopDetected >= 0)
                        {
                            if(approach  == -1)
                            {
                                if(withStandardMeshExport)
                                {
                                    self.export(isOBJ: true, meshing: true, regenerateCloud: false, optimized: true, optimizedMaxPolygons: 200000, previousState: previousState);
                                }
                                else
                                {
                                    if self.openedDatabasePath == nil
                                    {
                                        self.save();
                                    }
                                }
                            }
                        }
                        else if(loopDetected < 0)
                        {
                            self.showToast(message: "Optimization failed!", seconds: 4.0)
                        }
                    })
                }
                else
                {
                    self.showToast(message: "Optimization canceled", seconds: 4.0)
                }
                self.updateState(state: .STATE_IDLE);
            })
        })
    }
    
    func stopMapping(ignoreSaving: Bool, offerPostProcessing: Bool = true, reason: String = "")
    {
        scanRecorder.stop(reason: reason)
        photoButton?.isHidden = true
        session.pause()
        locationManager?.stopUpdatingLocation()
        rtabmap?.setPausedMapping(paused: true)
        rtabmap?.stopCamera()
        if(mDataRecording) {
            // this will show the trajectory before saving
            self.rtabmap!.setGraphOptimization(enabled: false)
        }
        setGLCamera(type: 2)
        if(mState == .STATE_VISUALIZING_CAMERA)
        {
            self.rtabmap?.setLocalizationMode(enabled: false)
        }
        updateState(state: mState == .STATE_VISUALIZING_CAMERA || mState == .STATE_VISUALIZING_AND_MEASURING ? .STATE_VISUALIZING : .STATE_IDLE);
        
        if !ignoreSaving
        {
            if(mDataRecording || !offerPostProcessing)
            {
                // Go directly to save
                self.save()
            }
            else
            {
                dismiss(animated: true, completion: {
                    var msg = "Do you want to do standard graph optimization and make a nice assembled mesh now? This can be also done later using \"Optimize\" and \"Assemble\" menus."
                    let depthUsed = self.depthSupported && UserDefaults.standard.bool(forKey: "LidarMode")
                    if !depthUsed
                    {
                        msg = "Do you want to do standard graph optimization now? This can be also done later using \"Optimize\" menu."
                    }
                    let alert = UIAlertController(title: "Mapping Stopped! Optimize Now?", message: msg, preferredStyle: .alert)
                    if depthUsed {
                        let alertActionOnlyGraph = UIAlertAction(title: "Only Optimize", style: .default)
                        {
                            (UIAlertAction) -> Void in
                            self.optimization(withStandardMeshExport: false, approach: -1)
                        }
                        alert.addAction(alertActionOnlyGraph)
                    }
                    let alertActionNo = UIAlertAction(title: "Save First", style: .cancel) {
                        (UIAlertAction) -> Void in
                        self.save()
                    }
                    alert.addAction(alertActionNo)
                    let alertActionYes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        self.optimization(withStandardMeshExport: depthUsed, approach: -1)
                    }
                    alert.addAction(alertActionYes)
                    self.present(alert, animated: true, completion: nil)
                })
            }
        }
        else if(mMapNodes == 0)
        {
            updateState(state: State.STATE_WELCOME);
            statusLabel.text = ""
        }
    }
    func shareFile(_ fileUrl: URL) {
        let fileURL = NSURL(fileURLWithPath: fileUrl.path)

        // Create the Array which includes the files you want to share
        var filesToShare = [Any]()

        // Add the path of the file to the Array
        filesToShare.append(fileURL)

        // Make the activityViewContoller which shows the share-view
        let activityViewController = UIActivityViewController(activityItems: filesToShare, applicationActivities: nil)
        
        if let popoverController = activityViewController.popoverPresentationController {
            popoverController.sourceRect = CGRect(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2, width: 0, height: 0)
            popoverController.sourceView = self.view
            popoverController.permittedArrowDirections = UIPopoverArrowDirection(rawValue: 0)
        }

        // Show the share-view
        self.present(activityViewController, animated: true, completion: nil)
    }
    
    func openDatabase(fileUrl: URL) {
        
        if(mState == .STATE_CAMERA) {
            stopMapping(ignoreSaving: true, reason: "database opened")
        }
        scanRecorder.reset() // recorder folders of earlier scans belong to their own zips

        openedDatabasePath = fileUrl;
        let fileName: String = self.openedDatabasePath!.lastPathComponent
        
        var progressDialog = UIAlertController(title: "Loading", message: String(format: "Loading \"%@\". Please wait while point clouds and/or meshes are created...", fileName), preferredStyle: .alert)
        
        //  Show it to your users
        self.present(progressDialog, animated: true)

        updateState(state: .STATE_PROCESSING);
        var status = 0
        DispatchQueue.background(background: {
            self.optimizedGraphShown = true // Always reset to true when opening a database
            status = self.rtabmap!.openDatabase(databasePath: self.openedDatabasePath!.path, databaseInMemory: true, optimize: false, clearDatabase: false)
        }, completion:{
            // main thread
            if(status == -1) {
                self.dismiss(animated: true)
                self.showToast(message: "The map is loaded but optimization of the map's graph has failed, so the map cannot be shown. Change the Graph Optimizer approach used or enable/disable if the graph is optimized from graph end in \"Settings -> Mapping...\" and try opening again.", seconds: 4)
            }
            else if(status == -2) {
                self.dismiss(animated: true)
                self.showToast(message: "Failed to open database: Out of memory! Try again after lowering Point Cloud Density in Settings.", seconds: 4)
            }
            else {
                if(status >= 1 && status<=3) {
                    self.visualizationType = status-1;
                    self.updateState(state: .STATE_VISUALIZING);
                    self.resetNoTouchTimer(true);
                }
                else {
                    self.setGLCamera(type: 2);
                    self.updateState(state: .STATE_IDLE);
                    self.dismiss(animated: true)
                    self.showToast(message: "Database loaded!", seconds: 2)
                }
            }
            
        })
    }
    
    func closeVisualization()
    {
        updateState(state: .STATE_IDLE);
    }
    
    func rename(fileURL: URL)
    {
        //Step : 1
        let alert = UIAlertController(title: "Rename Scan", message: "RTAB-Map Database Name (*.db):", preferredStyle: .alert )
        //Step : 2
        let rename = UIAlertAction(title: "Rename", style: .default) { (alertAction) in
            let textField = alert.textFields![0] as UITextField
            if textField.text != "" {
                //Read TextFields text data
                let fileName = textField.text!+".db"
                let filePath = self.getDocumentDirectory().appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: filePath) {
                    let alert = UIAlertController(title: "File Already Exists", message: "Do you want to overwrite the existing file?", preferredStyle: .alert)
                    let yes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        
                        do {
                            try FileManager.default.moveItem(at: fileURL, to: URL(fileURLWithPath: filePath))
                            print("File \(fileURL) renamed to \(filePath)")
                        }
                        catch {
                            print("Error renaming file \(fileURL) to \(filePath)")
                        }
                        self.openLibrary()
                    }
                    alert.addAction(yes)
                    let no = UIAlertAction(title: "No", style: .cancel) {
                        (UIAlertAction) -> Void in
                    }
                    alert.addAction(no)
                    
                    self.present(alert, animated: true, completion: nil)
                } else {
                    do {
                        try FileManager.default.moveItem(at: fileURL, to: URL(fileURLWithPath: filePath))
                        print("File \(fileURL) renamed to \(filePath)")
                    }
                    catch {
                        print("Error renaming file \(fileURL) to \(filePath)")
                    }
                    self.openLibrary()
                }
            }
        }

        //Step : 3
        alert.addTextField { (textField) in
            var components = fileURL.lastPathComponent.components(separatedBy: ".")
            if components.count > 1 { // If there is a file extension
              components.removeLast()
                textField.text = components.joined(separator: ".")
            } else {
                textField.text = fileURL.lastPathComponent
            }
        }

        //Step : 4
        alert.addAction(rename)
        //Cancel action
        alert.addAction(UIAlertAction(title: "Cancel", style: .default) { (alertAction) in })

        self.present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }
    
    func exportOBJPLY()
    {
        //Step : 1
        let alert = UIAlertController(title: "Export Scan", message: "Model Name:", preferredStyle: .alert )
        //Step : 2
        let save = UIAlertAction(title: "Ok", style: .default) { (alertAction) in
            let textField = alert.textFields![0] as UITextField
            if textField.text != "" {
                self.dismiss(animated: true)
                //Read TextFields text data
                let fileName = textField.text! + (self.exportOBJPLYButton.title(for: .normal)!.contains("LAZ") ? ".laz" : ".zip")
                let filePath = self.getDocumentDirectory().appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: filePath) {
                    let alert = UIAlertController(title: "File Already Exists", message: "\(fileName) already exists, do you want to overwrite it?", preferredStyle: .alert)
                    let yes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        self.writeExportedFiles(fileName: textField.text!);
                    }
                    alert.addAction(yes)
                    let no = UIAlertAction(title: "No", style: .cancel) {
                        (UIAlertAction) -> Void in
                    }
                    alert.addAction(no)
                    
                    self.present(alert, animated: true, completion: nil)
                } else {
                    self.writeExportedFiles(fileName: textField.text!);
                }
            }
        }

        //Step : 3
        alert.addTextField { (textField) in
            if self.openedDatabasePath != nil && !self.openedDatabasePath!.path.isEmpty
            {
                var components = self.openedDatabasePath!.lastPathComponent.components(separatedBy: ".")
                if components.count > 1 { // If there is a file extension
                    components.removeLast()
                    textField.text = components.joined(separator: ".")
                } else {
                    textField.text = self.openedDatabasePath!.lastPathComponent
                }
            }
            else {
                textField.text = Date().getFormattedDate(format: "yyMMdd-HHmmss")
            }
        }

        //Step : 4
        alert.addAction(save)
        //Cancel action
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { (alertAction) in })

        self.present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }

    func writeExportedFiles(fileName: String)
    {
        let isLAZ = self.visualizationType==0 && self.exportOBJPLYButton.title(for: .normal)!.contains("LAZ")
        
        let alertView = UIAlertController(title: "Exporting", message: "Please wait while exporting data to \(fileName+(isLAZ ? ".laz" : ".zip"))...", preferredStyle: .alert)
        alertView.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.dismiss(animated: true)
            self.progressView = nil
            self.rtabmap!.cancelProcessing()
        }))
        
        let previousState = mState;

        updateState(state: .STATE_PROCESSING);
        
        present(alertView, animated: true, completion: {
            //  Add your progressbar after alert is shown (and measured)
            let margin:CGFloat = 8.0
            let rect = CGRect(x: margin, y: 84.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
            self.progressView = UIProgressView(frame: rect)
            self.progressView!.progress = 0
            self.progressView!.tintColor = self.view.tintColor
            alertView.view.addSubview(self.progressView!)
            
            let exportDir = self.getTmpDirectory().appendingPathComponent(self.RTABMAP_EXPORT_DIR)
           
            do {
                try FileManager.default.removeItem(at: exportDir)
            }
            catch
            {}
            
            do {
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            }
            catch
            {
                print("Failed adding export directory \(exportDir)")
                return
            }
            
            var success : Bool = false
            var zipFileUrl : URL!
            DispatchQueue.background(background: {
                print("Exporting to directory \(exportDir.path) with name \(fileName)")
                if(self.rtabmap!.writeExportedMesh(directory: exportDir.path, name: fileName))
                {
                    do {
                        let fileURLs = try FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)
                        if(!fileURLs.isEmpty)
                        {
                            if(isLAZ)
                            {
                                zipFileUrl = self.getDocumentDirectory().appendingPathComponent(fileName+".laz")
                                do {
                                    if FileManager.default.fileExists(atPath: zipFileUrl.path)
                                    {
                                        try FileManager.default.removeItem(at: zipFileUrl)
                                    }
                                    try FileManager.default.moveItem(at: fileURLs.first!, to: zipFileUrl)
                                    print("LAZ file \(zipFileUrl.path) created (size=\(zipFileUrl.fileSizeString)")
                                    success = true
                                }
                                catch
                                {
                                    print("Failed moving \(fileURLs.first!) to \(zipFileUrl.path)")
                                    return
                                }
                            }
                            else
                            {
                                do {
                                    zipFileUrl = try Zip.quickZipFiles(fileURLs, fileName: fileName) // Zip
                                    print("Zip file \(zipFileUrl.path) created (size=\(zipFileUrl.fileSizeString)")
                                    success = true
                                }
                                catch {
                                    print("Something went wrong while zipping")
                                }
                            }
                        }
                    } catch {
                        print("No files exported to \(exportDir)")
                        return
                    }
                }
                
            }, completion:{
                if self.progressView != nil
                {
                    self.dismiss(animated: true)
                }
                if(success)
                {
                    let alertShare = UIAlertController(title: "Mesh/Cloud Saved!", message: "\(fileName+(isLAZ ? ".laz" : ".zip")) (\(zipFileUrl.fileSizeString) successfully exported in Documents of RTAB-Map! Share it?", preferredStyle: .alert)
                    let alertActionYes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        self.shareFile(zipFileUrl)
                    }
                    alertShare.addAction(alertActionYes)
                    let alertActionNo = UIAlertAction(title: "No", style: .cancel) {
                        (UIAlertAction) -> Void in
                       
                    }
                    alertShare.addAction(alertActionNo)
                    
                    self.present(alertShare, animated: true, completion: nil)
                }
                else
                {
                    self.showToast(message: "Exporting mesh/cloud canceled!", seconds: 2)
                }
                self.updateState(state: previousState);
            })
        })
    }
    
    func updateDatabases()
    {
        databases.removeAll()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: getDocumentDirectory(), includingPropertiesForKeys: nil)
            // if you want to filter the directory contents you can do like this:
            
            let data = fileURLs.map { url in
                        (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast)
                    }
                    .sorted(by: { $0.1 > $1.1 }) // sort descending modification dates
                    .map { $0.0 } // extract file names
            databases = data.filter{ $0.pathExtension == "db" && $0.lastPathComponent != RTABMAP_TMP_DB && $0.lastPathComponent != RTABMAP_RECOVERY_DB }
            
        } catch {
            print("Error while enumerating files : \(error.localizedDescription)")
            return
        }
    }
    
    func openLibrary()
    {
        updateDatabases();
        
        if databases.isEmpty {
            return
        }
        
        let alertController = UIAlertController(title: "Library", message: nil, preferredStyle: .alert)
        let customView = VerticalScrollerView()
        customView.dataSource = self
        customView.delegate = self
        customView.reload()
        alertController.view.addSubview(customView)
        customView.translatesAutoresizingMaskIntoConstraints = false
        customView.topAnchor.constraint(equalTo: alertController.view.topAnchor, constant: 60).isActive = true
        customView.rightAnchor.constraint(equalTo: alertController.view.rightAnchor, constant: -10).isActive = true
        customView.leftAnchor.constraint(equalTo: alertController.view.leftAnchor, constant: 10).isActive = true
        customView.bottomAnchor.constraint(equalTo: alertController.view.bottomAnchor, constant: -45).isActive = true
        
        alertController.view.translatesAutoresizingMaskIntoConstraints = false
        alertController.view.heightAnchor.constraint(equalToConstant: 600).isActive = true
        alertController.view.widthAnchor.constraint(equalToConstant: 400).isActive = true

        customView.backgroundColor = .darkGray

        let selectAction = UIAlertAction(title: "Select", style: .default) { (action) in
            self.openDatabase(fileUrl: self.databases[self.currentDatabaseIndex])
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(selectAction)
        alertController.addAction(cancelAction)
        self.present(alertController, animated: true, completion: nil)
    }

    //MARK: Actions   
    @IBAction func stopAction(_ sender: UIButton) {
        stopMapping(ignoreSaving: false, reason: "stop button")
    }

    @IBAction func recordAction(_ sender: UIButton) {
        rtabmap?.setPausedMapping(paused: false);
        lowMemoryWarningShown = false
        updateState(state: .STATE_MAPPING)
        scanRecorder.start(configuration: session.configuration, dataRecording: mDataRecording)
        photoButton?.isHidden = !ScanRecorder.photosEnabled
    }
    
    @IBAction func newScanAction(_ sender: UIButton) {
        newScan()
    }
    
    @IBAction func closeVisualizationAction(_ sender: UIButton) {
        closeVisualization()
        rtabmap!.postExportation(visualize: false)
    }
    
    @IBAction func stopCameraAction(_ sender: UIButton) {
        appMovedToBackground();
    }
    
    @IBAction func exportOBJPLYAction(_ sender: UIButton) {
        exportOBJPLY()
    }
    
    @IBAction func libraryAction(_ sender: UIButton) {
        openLibrary();
    }
    @IBAction func rotateGridAction(_ sender: UISlider) {
        rtabmap!.setGridRotation((Float(sender.value)-90.0)/2.0)
        self.view.setNeedsDisplay()
    }
    @IBAction func clipDistanceAction(_ sender: UISlider) {
        rtabmap!.setOrthoCropFactor(Float(120-sender.value)/20.0 - 3.0)
        self.view.setNeedsDisplay()
    }
    
    @IBAction func removeMeasureAction(_ sender: UIButton) {
        self.rtabmap!.removeMeasure()
    }
    @IBAction func addMeasureAction(_ sender: UIButton) {
        self.rtabmap!.addMeasureButtonClicked()
    }
    @IBAction func teleportButtonAction(_ sender: UIButton) {
        self.rtabmap!.teleportButtonClicked()
    }
    func clearMeasures()
    {
        self.rtabmap!.clearMeasures()
        self.resetNoTouchTimer(true)
    }
    @IBAction func startMeasuring(_ sender: UIButton) {
        self.setGLCamera(type: 0)
        self.updateState(state: .STATE_VISUALIZING_AND_MEASURING)
        self.startCamera()
    }
}

func clearBackgroundColor(of view: UIView) {
    if let effectsView = view as? UIVisualEffectView {
        effectsView.removeFromSuperview()
        return
    }

    view.backgroundColor = .clear
    view.subviews.forEach { (subview) in
        clearBackgroundColor(of: subview)
    }
}

extension ViewController: GLKViewControllerDelegate {
    
    // OPENGL UPDATE
    func glkViewControllerUpdate(_ controller: GLKViewController) {
        
    }
    
    // OPENGL DRAW
    override func glkView(_ view: GLKView, drawIn rect: CGRect) {
        if let rotation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        {
            let viewportSize = CGSize(width: rect.size.width * view.contentScaleFactor, height: rect.size.height * view.contentScaleFactor)
            rtabmap?.setupGraphic(size: viewportSize, orientation: rotation)
        }

        let value = rtabmap?.render()
        
        DispatchQueue.main.async {
            if(value != 0 && self.progressView != nil)
            {
                print("Render dismissing")
                self.dismiss(animated: true)
                self.progressView = nil
            }
            if(value == -1)
            {
                self.showToast(message: "Out of Memory!", seconds: 2)
            }
            else if(value == -2)
            {
                self.showToast(message: "Rendering Error!", seconds: 2)
            }
        }
    }
}

extension Date {
   func getFormattedDate(format: String) -> String {
        let dateformat = DateFormatter()
        dateformat.dateFormat = format
        return dateformat.string(from: self)
    }
    
    var millisecondsSince1970:Int64 {
        Int64((self.timeIntervalSince1970 * 1000.0).rounded())
    }
    
    init(milliseconds:Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

extension DispatchQueue {

    static func background(delay: Double = 0.0, background: (()->Void)? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            background?()
            if let completion = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: {
                    completion()
                })
            }
        }
    }
}

extension ViewController: VerticalScrollerViewDelegate {
    func verticalScrollerView(_ horizontalScrollerView: VerticalScrollerView, didSelectViewAt index: Int) {
    //1
    let previousDatabaseView = horizontalScrollerView.view(at: currentDatabaseIndex) as! DatabaseView
    previousDatabaseView.highlightDatabase(false)
    //2
    currentDatabaseIndex = index
    //3
    let databaseView = horizontalScrollerView.view(at: currentDatabaseIndex) as! DatabaseView
    databaseView.highlightDatabase(true)
    //4
  }
}

extension ViewController: VerticalViewDataSource {
  func numberOfViews(in horizontalScrollerView: VerticalScrollerView) -> Int {
    return databases.count
  }
  
  func getScrollerViewItem(_ horizontalScrollerView: VerticalScrollerView, viewAt index: Int) -> UIView {
    print(databases[index].path)
    let databaseView = DatabaseView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), databaseURL: databases[index])

    databaseView.delegate = self
    
    if currentDatabaseIndex == index {
        databaseView.highlightDatabase(true)
    } else {
        databaseView.highlightDatabase(false)
    }

    return databaseView
  }
}

extension ViewController: DatabaseViewDelegate {
    func databaseShared(databaseURL: URL) {
        self.dismiss(animated: true)
        self.shareFile(databaseURL)
    }
    
    func databaseRenamed(databaseURL: URL) {
        self.dismiss(animated: true)
        
        if(openedDatabasePath?.lastPathComponent == databaseURL.lastPathComponent)
        {
            let alertController = UIAlertController(title: "Rename Database", message: "Database \(databaseURL.lastPathComponent) is already opened, cannot rename it.", preferredStyle: .alert)
            let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
            }
            alertController.addAction(okAction)
            present(alertController, animated: true)
            return
        }
        
        self.rename(fileURL: databaseURL)
    }
    
    func databaseDeleted(databaseURL: URL) {
        self.dismiss(animated: true)
        
        if(openedDatabasePath?.lastPathComponent == databaseURL.lastPathComponent)
        {
            let alertController = UIAlertController(title: "Delete Database", message: "Database \(databaseURL.lastPathComponent) is already opened, cannot delete it.", preferredStyle: .alert)
            let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
            }
            alertController.addAction(okAction)
            present(alertController, animated: true)
            return
        }
        
        do {
            try FileManager.default.removeItem(at: databaseURL)
            print("File \(databaseURL) deleted")
        }
        catch {
            print("Error deleting file \(databaseURL)")
        }
        self.updateDatabases()
        if(!databases.isEmpty)
        {
            self.openLibrary()
        }
        else {
            self.updateState(state: self.mState)
        }
    }
  }

extension UserDefaults {
    func reset() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys.forEach(defaults.removeObject(forKey:))
        
        setDefaultsFromSettingsBundle()
    }
}

extension SKStoreReviewController {
    public static func requestReviewInCurrentScene() {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            requestReview(in: scene)
        }
    }
}

// MARK: - Scan recorder: audio and high-resolution photos alongside the RTAB-Map scan

extension ViewController {
    func setupScanRecorder() {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "camera.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44)), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.addTarget(self, action: #selector(photoButtonPressed), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        photoButton = button
        if ScanRecorder.audioEnabled {
            // Ask now: a permission alert while mapping makes the app resign active, which stops the scan
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        }
        scanRecorder.notify = { [weak self] message in
            DispatchQueue.main.async { self?.showToast(message: message, seconds: 3) }
        }
    }

    @objc func photoButtonPressed() {
        scanRecorder.requestPhoto()
    }
}

/// Writes Documents/skanneri/<yyMMdd-HHmmss>/ while mapping: istunto.json (device, build, formats), asetukset.json (app settings),
/// liike.csv (ARKit camera pose at 10 Hz), tila.csv (memory, heat, battery, frame rate, tracking and map stats at 1 Hz),
/// tapahtumat.csv (toasts, alerts, tracking changes, interruptions and why mapping stopped), loki.txt (native stderr),
/// puhe.wav (16 kHz mono PCM, start time in aani.json) and kuvat/*.jpg with kuvat.csv (high-resolution photos).
/// All times are epoch seconds on the same clock as RTAB-Map node stamps (see CameraMobile stampEpochOffset_).
final class ScanRecorder {
    static var audioEnabled: Bool { UserDefaults.standard.object(forKey: "RecordAudio") as? Bool ?? true }
    static var photosEnabled: Bool { UserDefaults.standard.object(forKey: "HighResPhotos") as? Bool ?? true }
    /// Take photos automatically when the device is still; off by default (camera button only)
    static var autoPhotosEnabled: Bool { UserDefaults.standard.object(forKey: "AutoPhotos") as? Bool ?? false }
    /// Video format recommended for high-resolution capture; off by default because it may degrade tracking
    static var highResFormatEnabled: Bool { UserDefaults.standard.object(forKey: "HighResVideoFormat") as? Bool ?? false }

    var notify: ((String) -> Void)?
    private(set) var running = false
    private var folder: URL?
    private var folders: [URL] = []
    private var epochOffset: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var motionFile: FileHandle?
    private var photoFile: FileHandle?
    private var statusFile: FileHandle?
    private var eventFile: FileHandle?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "skanneri.recorder")
    private let ciContext = CIContext()

    // 1 Hz status (main thread): ARKit frames and the slowest frame since the last row, last values seen
    private var lastStatus: TimeInterval?
    private var frameCount = 0
    private var maxProcessing: TimeInterval = 0
    private var maxLag: TimeInterval = 0
    private var trackingState = ""
    private var mappingStatus = ""
    private var mapStats = ""
    private static let mapStatsEmpty = ",,,,,,,"
    // Last notice written to tapahtumat.csv (recorder queue); the same toast is posted on every frame while tracking is limited
    private var lastNotice: (text: String, epoch: TimeInterval)?

    // Automatic photo: still for 0.4 s, at least 1 s and 0.3 m or 15 deg from the previous photo
    private var lastSample: (t: TimeInterval, pose: simd_float4x4)?
    private var stillSince: TimeInterval?
    private var lastPhoto: (t: TimeInterval, pose: simd_float4x4)?
    private var photoPending = false
    private var photoRequested = false
    private let maxSpeed: Float = 0.05
    private let maxTurnRate: Float = 10 * .pi / 180
    private let stillTime: TimeInterval = 0.4
    private let minPhotoInterval: TimeInterval = 1.0
    private let minPhotoDistance: Float = 0.3
    private let minPhotoTurn: Float = 15 * .pi / 180
    private let minFreeBytes: Int64 = 2_000_000_000

    private static let matrixHeader = (0..<4).flatMap { r in (0..<4).map { c in "m\(r)\(c)" } }.joined(separator: ",")

    func start(configuration: ARConfiguration? = nil, dataRecording: Bool = false) {
        guard !running else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd-HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("skanneri").appendingPathComponent(formatter.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("kuvat"), withIntermediateDirectories: true)
        } catch {
            notify?("Scan recorder: could not create folder")
            return
        }
        folder = dir
        folders.append(dir)
        epochOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        var info: [String: Any] = ["epoch_offset": epochOffset, "alku_epoch": Date().timeIntervalSince1970, "versio": "skanneri-3",
                                   "high_res_photos": ScanRecorder.photosEnabled, "high_res_format": ScanRecorder.highResFormatEnabled,
                                   "auto_photos": ScanRecorder.autoPhotosEnabled, "data_recording": dataRecording]
        if let format = configuration?.videoFormat {
            info["video_format"] = ScanRecorder.describe(format)
        }
        info["supported_formats"] = ARWorldTrackingConfiguration.supportedVideoFormats.map { ScanRecorder.describe($0) }
        UIDevice.current.isBatteryMonitoringEnabled = true
        info.merge(ScanRecorder.deviceInfo()) { current, _ in current }
        writeJSON(info, to: dir.appendingPathComponent("istunto.json"))
        writeJSON(["settings": ScanRecorder.settings()], to: dir.appendingPathComponent("asetukset.json"))
        motionFile = openCSV(dir.appendingPathComponent("liike.csv"), header: "arkit_t,epoch," + ScanRecorder.matrixHeader)
        photoFile = openCSV(dir.appendingPathComponent("kuvat.csv"),
                            header: "tiedosto,arkit_t,epoch," + ScanRecorder.matrixHeader + ",fx,fy,cx,cy,leveys,korkeus,syvyys_m,valotus_ms")
        statusFile = openCSV(dir.appendingPathComponent("tila.csv"),
                             header: "epoch,arkit_t,kehyksia_s,kasittely_max_ms,viive_max_ms,seuranta,kartoitus,piirteet,valotus_ms,valo,varilampo," +
                                "muisti_vapaa_mt,muisti_kaytossa_mt,lampo,akku,lataus,virransaasto," +
                                "solmut,piirretyt,sanat,pisteet,polygonit,paivitys_ms,fps_piirto,tietokanta_mt,levy_vapaa_mt")
        eventFile = openCSV(dir.appendingPathComponent("tapahtumat.csv"), header: "epoch,tyyppi,teksti")
        // Native errors (LOGE) go to stderr, which is otherwise lost on the device
        freopen(dir.appendingPathComponent("loki.txt").path, "a", stderr)
        setvbuf(stderr, nil, _IOLBF, 0)  // freopen makes stderr buffered; keep lines that precede a crash
        observe()
        running = true
        event("aloitus", dir.lastPathComponent)
        if ScanRecorder.audioEnabled {
            startAudio(dir)
        }
    }

    func stop(reason: String = "") {
        guard running else { return }
        event("pysaytys", reason)
        running = false
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        queue.async {
            self.motionFile?.closeFile()
            self.motionFile = nil
            self.photoFile?.closeFile()
            self.photoFile = nil
            self.statusFile?.closeFile()
            self.statusFile = nil
            self.eventFile?.closeFile()
            self.eventFile = nil
            self.lastNotice = nil
        }
        lastSample = nil
        stillSince = nil
        lastPhoto = nil
        photoRequested = false
        photoPending = false
        lastStatus = nil
        trackingState = ""
        mappingStatus = ""
        mapStats = ""
    }

    /// Append a row to tapahtumat.csv; callable from any thread. Repeats of the same notice within 2 s are skipped.
    func event(_ type: String, _ text: String = "") {
        let epoch = Date().timeIntervalSince1970
        queue.async {
            guard let file = self.eventFile else { return }
            if type == "ilmoitus" {
                if let last = self.lastNotice, last.text == text, epoch - last.epoch < 2 { return }
                self.lastNotice = (text, epoch)
            }
            let quoted = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            _ = try? file.write(contentsOf: (String(format: "%.3f,", epoch) + type + "," + quoted + "\n").data(using: .utf8)!)
        }
    }

    /// Latest RTAB-Map statistics for tila.csv (main thread, about once per map update).
    func stats(nodes: Int, nodesDrawn: Int, words: Int, points: Int, polygons: Int, updateTime: Float, fps: Float, databaseMemoryUsed: Int) {
        guard running else { return }
        mapStats = String(format: "%ld,%ld,%ld,%ld,%ld,%.0f,%.1f,%ld", nodes, nodesDrawn, words, points, polygons, updateTime, fps, databaseMemoryUsed)
    }

    private func add(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil, using: handler))
    }

    private func observe() {
        add(ProcessInfo.thermalStateDidChangeNotification) { _ in
            self.event("lampo", ScanRecorder.thermalName(ProcessInfo.processInfo.thermalState))
        }
        add(UIApplication.didReceiveMemoryWarningNotification) { _ in
            self.event("muistivaroitus", "iOS memory warning, \(os_proc_available_memory() / 1_048_576) MB free")
        }
        add(Notification.Name.NSProcessInfoPowerStateDidChange) { _ in
            self.event("virransaasto", ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")
        }
        add(AVAudioSession.interruptionNotification) { note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            self.event("aani", type == AVAudioSession.InterruptionType.began.rawValue ? "interruption began" : "interruption ended")
        }
        add(AVAudioSession.routeChangeNotification) { note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            self.event("aani", "route change, reason \(reason.map { String($0) } ?? "?")")
        }
    }

    func requestPhoto() {
        photoRequested = true
    }

    /// Forget folders of the previous scan (called when a new scan starts).
    func reset() {
        folders = []
    }

    /// Zip the saved database and this scan's recorder folders to Documents/<database name>.zip.
    /// Runs on the recorder queue, after the CSV files queued by stop() are closed. The zip is written as
    /// <name>-kesken.zip and renamed when complete, so a half-written zip is never copied by mistake.
    func package(database: URL) {
        let name = database.deletingPathExtension().lastPathComponent
        let paths = [database] + folders
        queue.async {
            // Stop appending native errors to loki.txt while it is being zipped
            freopen("/dev/null", "a", stderr)
            // Zip off the recorder queue, so photos of a scan started meanwhile are not held up
            DispatchQueue.global(qos: .utility).async {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let target = docs.appendingPathComponent(name + ".zip")
                let partial = name + "-kesken"
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.removeItem(at: docs.appendingPathComponent(partial + ".zip"))
                do {
                    let zip = try Zip.quickZipFiles(paths, fileName: partial)
                    try FileManager.default.moveItem(at: zip, to: target)
                    self.notify?("Saved \(target.lastPathComponent) (\(target.fileSizeString))")
                } catch {
                    self.notify?("Could not create \(name).zip: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Called for every ARFrame on the main thread; processingTime is how long RTAB-Map's odometry event took for this frame.
    func process(frame: ARFrame, session: ARSession, processingTime: TimeInterval = 0) {
        guard running else { return }
        let t = frame.timestamp
        let pose = frame.camera.transform
        track(frame, processingTime: processingTime)
        if let last = lastSample, t - last.t < 0.1 {
            return
        }
        let line = String(format: "%.6f,%.6f,", t, t + epochOffset) + ScanRecorder.matrixString(pose) + "\n"
        queue.async { _ = try? self.motionFile?.write(contentsOf: line.data(using: .utf8)!) }

        if let last = lastSample {
            let dt = Float(t - last.t)
            let speed = simd_distance(ScanRecorder.position(pose), ScanRecorder.position(last.pose)) / dt
            let turnRate = ScanRecorder.angle(last.pose, pose) / dt
            if speed < maxSpeed && turnRate < maxTurnRate {
                stillSince = stillSince ?? last.t
            } else {
                stillSince = nil
            }
        }
        lastSample = (t, pose)

        guard ScanRecorder.photosEnabled, !photoPending else { return }
        var trigger = photoRequested
        if ScanRecorder.autoPhotosEnabled, let since = stillSince, t - since >= stillTime {
            if let previous = lastPhoto {
                trigger = trigger || (t - previous.t >= minPhotoInterval &&
                    (simd_distance(ScanRecorder.position(pose), ScanRecorder.position(previous.pose)) >= minPhotoDistance ||
                     ScanRecorder.angle(previous.pose, pose) >= minPhotoTurn))
            } else {
                trigger = true
            }
        }
        if trigger {
            if #available(iOS 16.0, *) {
                capturePhoto(session, depth: ScanRecorder.centerDepth(frame))
            }
        }
    }

    /// Frame rate, slowest frame, tracking and world mapping changes; one tila.csv row per second.
    private func track(_ frame: ARFrame, processingTime: TimeInterval) {
        let t = frame.timestamp
        frameCount += 1
        maxProcessing = max(maxProcessing, processingTime)
        maxLag = max(maxLag, CACurrentMediaTime() - t)
        let tracking = ScanRecorder.trackingName(frame.camera.trackingState)
        if tracking != trackingState {
            event("seuranta", tracking)
            trackingState = tracking
        }
        let mapping = ScanRecorder.mappingName(frame.worldMappingStatus)
        if mapping != mappingStatus {
            event("kartoitus", mapping)
            mappingStatus = mapping
        }
        guard let last = lastStatus else {
            lastStatus = t
            return
        }
        guard t - last >= 1 else { return }
        var exposure = ""
        if #available(iOS 16.0, *) {
            exposure = String(format: "%.2f", frame.camera.exposureDuration * 1000)
        }
        let light = frame.lightEstimate.map { String(format: "%.0f,%.0f", $0.ambientIntensity, $0.ambientColorTemperature) } ?? ","
        let process = ProcessInfo.processInfo
        let device = UIDevice.current
        var fields: [String] = [String(format: "%.3f", t + epochOffset), String(format: "%.6f", t),
                                String(format: "%.1f", Double(frameCount) / (t - last)),
                                String(format: "%.1f", maxProcessing * 1000), String(format: "%.1f", maxLag * 1000)]
        fields += [tracking, mapping, String(frame.rawFeaturePoints?.points.count ?? 0), exposure, light]
        fields += [String(os_proc_available_memory() / 1_048_576), String(ScanRecorder.footprintMB()), String(process.thermalState.rawValue)]
        fields += [String(format: "%.2f", device.batteryLevel), String(device.batteryState.rawValue), process.isLowPowerModeEnabled ? "1" : "0"]
        fields.append(mapStats.isEmpty ? ScanRecorder.mapStatsEmpty : mapStats)
        let start = fields.joined(separator: ",")
        queue.async {
            _ = try? self.statusFile?.write(contentsOf: (start + ",\(ScanRecorder.freeBytes() / 1_048_576)\n").data(using: .utf8)!)
        }
        lastStatus = t
        frameCount = 0
        maxProcessing = 0
        maxLag = 0
    }

    @available(iOS 16.0, *)
    private func capturePhoto(_ session: ARSession, depth: Float?) {
        let manual = photoRequested
        photoRequested = false
        guard let dir = folder else { return }
        guard ScanRecorder.freeBytes() > minFreeBytes else {
            // Only for button presses: automatic photos would retrigger on every frame
            if manual {
                event("kuva", "skipped: less than 2 GB free storage")
                notify?("Photo skipped: less than 2 GB free storage")
            }
            return
        }
        photoPending = true
        let offset = epochOffset
        session.captureHighResolutionFrame { frame, error in
            guard let frame = frame else {
                self.event("kuva", "capture failed: \(error?.localizedDescription ?? "unknown error")")
                DispatchQueue.main.async { self.photoPending = false }
                return
            }
            let t = frame.timestamp
            let pose = frame.camera.transform
            let K = frame.camera.intrinsics
            let exposure = frame.camera.exposureDuration * 1000
            let width = CVPixelBufferGetWidth(frame.capturedImage)
            let height = CVPixelBufferGetHeight(frame.capturedImage)
            let name = String(format: "%.0f.jpg", (t + offset) * 1000)
            let image = CIImage(cvPixelBuffer: frame.capturedImage)
            DispatchQueue.main.async { self.lastPhoto = (t, pose) }
            self.queue.async {
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                if let jpeg = self.ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                options: [quality: 0.9]) {
                    do {
                        try jpeg.write(to: dir.appendingPathComponent("kuvat").appendingPathComponent(name))
                        let depthText: String = depth.map { String(format: "%.3f", $0) } ?? ""
                        let line = name + String(format: ",%.6f,%.6f,", t, t + offset) + ScanRecorder.matrixString(pose) +
                            String(format: ",%.3f,%.3f,%.3f,%.3f,%ld,%ld,", K[0][0], K[1][1], K[2][0], K[2][1], width, height) +
                            depthText + String(format: ",%.2f\n", exposure)
                        _ = try? self.photoFile?.write(contentsOf: line.data(using: .utf8)!)
                    } catch {
                        self.event("kuva", "could not write \(name): \(error.localizedDescription)")
                    }
                } else {
                    self.event("kuva", "JPEG encoding failed: \(name)")
                }
                DispatchQueue.main.async { self.photoPending = false }
            }
        }
    }

    private func startAudio(_ dir: URL) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard self.running else { return }
                guard granted else {
                    self.notify?("Microphone permission denied: scanning without audio")
                    return
                }
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
                    try audioSession.setActive(true)
                    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                                                   AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                   AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                    let recorder = try AVAudioRecorder(url: dir.appendingPathComponent("puhe.wav"), settings: settings)
                    let startEpoch = Date().timeIntervalSince1970
                    if recorder.record() {
                        self.recorder = recorder
                        self.writeJSON(["alku_epoch": startEpoch], to: dir.appendingPathComponent("aani.json"))
                    } else {
                        self.notify?("Audio recording did not start")
                    }
                } catch {
                    self.notify?("Audio recording did not start: \(error.localizedDescription)")
                }
            }
        }
    }

    private func openCSV(_ url: URL, header: String) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: (header + "\n").data(using: .utf8))
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }

    private func writeJSON(_ object: [String: Any], to url: URL) {
        // JSONSerialization raises an Objective-C exception (crash) on invalid objects instead of throwing
        guard JSONSerialization.isValidJSONObject(object) else { return }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    private static func matrixString(_ m: simd_float4x4) -> String {
        // Row-major m00..m33; simd stores columns, so m[c][r] is row r, column c
        (0..<4).flatMap { r in (0..<4).map { c in String(format: "%.6f", m[c][r]) } }.joined(separator: ",")
    }

    private static func position(_ m: simd_float4x4) -> simd_float3 {
        simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private static func angle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let d = simd_quatf(b) * simd_quatf(a).inverse
        let x = d.angle
        return min(x, 2 * .pi - x)
    }

    private static func describe(_ format: ARConfiguration.VideoFormat) -> [String: Any] {
        var d: [String: Any] = ["width": Int(format.imageResolution.width), "height": Int(format.imageResolution.height),
                                "fps": format.framesPerSecond]
        if #available(iOS 14.5, *) {
            d["device"] = format.captureDeviceType.rawValue
        }
        if #available(iOS 16.0, *) {
            d["high_res_recommended"] = format.isRecommendedForHighResolutionFrameCapturing
        }
        return d
    }

    private static func trackingName(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(.excessiveMotion): return "limited:excessiveMotion"
        case .limited(.insufficientFeatures): return "limited:insufficientFeatures"
        case .limited(.initializing): return "limited:initializing"
        case .limited(.relocalizing): return "limited:relocalizing"
        default: return "limited:other"
        }
    }

    private static func mappingName(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Memory the app is charged for (the figure the system memory limit applies to), MB
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// Device, iPadOS, build and signing for istunto.json; SkanneriCommit and SkanneriRun are added to Info.plist by the GitHub build
    private static func deviceInfo() -> [String: Any] {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let bundle = Bundle.main
        var info: [String: Any] = ["laite": model, "ios": UIDevice.current.systemVersion,
                                   "sovellus_versio": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                   "commit": bundle.object(forInfoDictionaryKey: "SkanneriCommit") as? String ?? "",
                                   "ajo": bundle.object(forInfoDictionaryKey: "SkanneriRun") as? String ?? "",
                                   "muisti_vapaa_mt": os_proc_available_memory() / 1_048_576, "muisti_kaytossa_mt": footprintMB(),
                                   "levy_vapaa_mt": freeBytes() / 1_048_576,
                                   "lampo": thermalName(ProcessInfo.processInfo.thermalState),
                                   "akku": UIDevice.current.batteryLevel, "virransaasto": ProcessInfo.processInfo.isLowPowerModeEnabled]
        if let expiry = provisionExpiry() {
            info["allekirjoitus_vanhenee"] = ISO8601DateFormatter().string(from: expiry)
        }
        return info
    }

    /// Expiry of the provisioning profile Sideloadly embedded (7 days with a free Apple ID)
    private static func provisionExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound),
                                                                     format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// Median LiDAR depth (m) in the central 5 × 5 pixels of the depth map, nil without valid depth
    private static func centerDepth(_ frame: ARFrame) -> Float? {
        guard let map = frame.sceneDepth?.depthMap, CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map), rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard let base = CVPixelBufferGetBaseAddress(map), width >= 5, height >= 5 else { return nil }
        var values: [Float] = []
        for y in (height / 2 - 2)...(height / 2 + 2) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in (width / 2 - 2)...(width / 2 + 2) where row[x].isFinite && row[x] > 0 {
                values.append(row[x])
            }
        }
        return values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    /// Every Settings.bundle value in effect (iOS Settings → app, pages Root, Mapping and Assembling), in page order.
    /// Rendering and depth settings are not stored in the database, so asetukset.json is the only record of them.
    private static func settings() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for page in ["Root", "Mapping", "Assembling"] {
            guard let url = Bundle.main.url(forResource: page, withExtension: "plist", subdirectory: "Settings.bundle"),
                  let plist = NSDictionary(contentsOf: url),
                  let specifiers = plist["PreferenceSpecifiers"] as? [[String: Any]] else { continue }
            var group = ""
            for spec in specifiers {
                if spec["Type"] as? String == "PSGroupSpecifier" {
                    group = spec["Title"] as? String ?? ""
                }
                guard let key = spec["Key"] as? String else { continue }
                let value = UserDefaults.standard.object(forKey: key) ?? spec["DefaultValue"]
                var entry: [String: Any] = ["page": page, "group": group, "title": spec["Title"] as? String ?? key, "key": key,
                                            "value": value ?? NSNull(), "default": spec["DefaultValue"] ?? NSNull()]
                // Multi-value settings: also the label shown in Settings
                if let values = spec["Values"] as? [NSObject], let titles = spec["Titles"] as? [String], let v = value as? NSObject,
                   let i = values.firstIndex(of: v), i < titles.count {
                    entry["value_title"] = titles[i]
                }
                result.append(entry)
            }
        }
        return result
    }

    private static func freeBytes() -> Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
