import ARKit
import SceneKit
import UIKit
import Foundation

class ViewController: UIViewController, ARSCNViewDelegate {

    @IBOutlet var sceneView: ARSCNView!
    @IBOutlet var counterLabel: UILabel!

    let configuration = ARWorldTrackingConfiguration()
    
    /// Coordinates of last placed point
    var lastObjectPlacedPoint: SCNVector3?
    
    /// Node selected by user
    var selectedNode: SCNNode?
    
    /// Nodes placed by the user
    var placedNodes:[SCNNode?] = [SCNNode]()
    
    /// Visualization planes placed when detecting planes
    var planeNodes = [SCNNode]()
    
    var focusSquare = FocusSquare()
    var screenCenter: CGPoint {
        let bounds = sceneView.bounds
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }
    
    /// Defines whether plane visualisation is shown
    var showPlaneOverlay = false {
        didSet {
            for node in planeNodes {
                node.isHidden = !showPlaneOverlay
            }
        }
    }
    
    enum ObjectPlacementMode {
        case freeform, plane, image
    }
    
    var objectMode: ObjectPlacementMode = .freeform {
        didSet {
            reloadConfiguration(removeAnchors: false)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sceneView.delegate = self
        sceneView.autoenablesDefaultLighting = true
        sceneView.scene.physicsWorld.contactDelegate = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadConfiguration(removeAnchors: false)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    @IBAction func changeObjectMode(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 0:
            objectMode = .freeform
            showPlaneOverlay = false
        case 1:
            objectMode = .plane
            showPlaneOverlay = true
        case 2:
            objectMode = .image
            showPlaneOverlay = false
        default:
            break
        }
    }
    
    @IBAction func undoButton(_ sendet: UIButton) {
        undoLastObject()
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showOptions" {
            let optionsViewController = segue.destination as! OptionsContainerViewController
            optionsViewController.delegate = self
        }
    }
}

extension ViewController: OptionsViewControllerDelegate {
    
    /// Called when user selects an object
    ///
    /// - Parameter node: SCNNode of an object selected by user
    func objectSelected(node: SCNNode) {
        dismiss(animated: true, completion: nil)
        selectedNode = node
    }
    
    func togglePlaneVisualization() {
        dismiss(animated: true, completion: nil)
        showPlaneOverlay.toggle()
    }
    
    func undoLastObject() {

        let lastNodeOptional = placedNodes.compactMap{$0}.last
        guard let lastNode = lastNodeOptional else {
            dismiss(animated: true, completion: nil)
            return
        }
        
        placedNodes.remove(at: Int(lastNode.name!)!)
        lastNode.removeFromParentNode()
    }
    
    func resetScene() {
        dismiss(animated: true, completion: nil)
        reloadConfiguration()
    }
}

// MARK: - Touches
extension ViewController {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        
        guard let touch = touches.first else { return }
        guard let node = selectedNode else { return }
        
        switch objectMode {
        case .freeform:
            addNodeInFront(node)
        case .plane:
            let point = touch.location(in: sceneView)
            addNode(node, to: point)
        case .image:
            break
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
            
        guard let selectedNode = selectedNode else { return }
        guard let touch = touches.first else { return }

        let currentTouchPoint = touch.location(in: sceneView)
        
        switch objectMode {
        case .freeform:
            addNodeInFront(selectedNode)
        case .image:
            break
        case .plane:
            addNode(selectedNode, to: currentTouchPoint)
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        lastObjectPlacedPoint = nil
    }
}

// MARK: - Placement Methods
extension ViewController {
    /// Adds a node to parent node
    ///
    /// - Parameters:
    ///   - node: nodes which will to be added
    ///   - parentNode: parent node to which the node to be added
    func addNode(_ node: SCNNode, to parentNode: SCNNode, isFloor: Bool = false) {
        let cloneNode = isFloor ? node : node.clone()
        
        if !isFloor {
 
            var physicsShape = SCNPhysicsShape()
            if let geometry = cloneNode.geometry {
                physicsShape = SCNPhysicsShape(geometry: geometry, options: nil)
            } else {
                let minX = cloneNode.boundingBox.min.x
                let minY = cloneNode.boundingBox.min.y
                let minZ = cloneNode.boundingBox.min.z
                let maxX = cloneNode.boundingBox.max.x
                let maxY = cloneNode.boundingBox.max.y
                let maxZ = cloneNode.boundingBox.max.z
                let geometry = SCNBox(width: CGFloat(maxX - minX), height: CGFloat(maxY - minY), length: CGFloat(maxZ - minZ), chamferRadius: 0)
                physicsShape = SCNPhysicsShape(geometry: geometry, options: nil)
            }
            
            cloneNode.physicsBody = SCNPhysicsBody(type: .dynamic, shape: physicsShape)
            cloneNode.physicsBody!.isAffectedByGravity = false
            cloneNode.physicsBody!.categoryBitMask = 1 << 0
            cloneNode.physicsBody!.collisionBitMask = 0 << 0
            cloneNode.physicsBody!.contactTestBitMask = 1 << 0
            
            cloneNode.name = String(placedNodes.count)
        }
        
        parentNode.addChildNode(cloneNode)
        
        
        if isFloor {
            planeNodes.append(cloneNode)
        } else {
            placedNodes.append(cloneNode)
        }
    }
    
    /// Adds a node using a point at the screen
    ///
    /// - Parameters:
    ///   - node: selected node to add
    ///   - point: point at the screen to use
    func addNode(_ node: SCNNode, to point: CGPoint) {
        
        guard let transform = getSimdTransform(from: point) else { return }
    
        node.position = getPointPosition(from: transform)
        
        addNodeToSceneRoot(node)
        
        lastObjectPlacedPoint = node.position
    }
    
    /// Places object defined by node at 20 cm before the camera
    ///
    /// - Parameter node: SCNNode to place in scene
    func addNodeInFront(_ node: SCNNode) {
        guard let transform = getSimdTransform() else { return }
        
        node.simdTransform = transform
        node.eulerAngles.z = -.pi * 2
        
        addNodeToSceneRoot(node)
        
        lastObjectPlacedPoint = getPointPosition(from: node.simdTransform)
    }
    
    /// Get simdTransform for "freeForm" object mode
    ///
    /// - Returns: simd_float4x4?
    func getSimdTransform() -> simd_float4x4? {
        guard let currentFrame = sceneView.session.currentFrame else { return nil }
        
        var translation = matrix_identity_float4x4
        translation.columns.3.z = -0.2
        return matrix_multiply(currentFrame.camera.transform, translation)
    }
    
    /// Get simdTransform for "plane" object mode
    ///
    /// - Parameter point: CGPoint
    /// - Returns: simd_float4x4?
    func getSimdTransform(from point: CGPoint) -> simd_float4x4? {
        let results = sceneView.hitTest(point, types: [.existingPlaneUsingExtent])
        
        guard let match = results.first else { return nil}
        
        return match.worldTransform
    }
    
    
    /// Get current point position from .simdTransform
    ///
    /// - Parameter transform: simd_float4x4
    /// - Returns: SCNVector3
    func getPointPosition(from transform : simd_float4x4) -> SCNVector3 {
        let translate = transform.columns.3
        let x = translate.x
        let y = translate.y
        let z = translate.z
        
        return SCNVector3(x, y, z)
    }

    
    /// Clones and adds an object defined by node to scene root
    ///
    /// - Parameter node: SCNNode which will be added
    func addNodeToSceneRoot(_ node: SCNNode) {
        let rootNode = sceneView.scene.rootNode
        addNode(node, to: rootNode)
    }
    
    /// Creates visualization plane
    ///
    /// - Parameter planeAnchor: anchor attached to the plane
    /// - Returns: node of created visualization plane
    func createFloor(planeAnchor: ARPlaneAnchor) -> SCNNode {
        let extent = planeAnchor.extent
        let geometry = SCNPlane(width: CGFloat(extent.x), height: CGFloat(extent.z))
        //geometry.firstMaterial?.diffuse.contents = UIColor.blue
        
        let node = SCNNode(geometry: geometry)
        
        node.eulerAngles.x = -.pi / 2
        node.opacity = 0
        
        return node
    }
    
    /// Plane node AR anchor has been added to the scene
    ///
    /// - Parameters:
    ///   - node: node which was added
    ///   - anchor: AR plane anchor which defines the plane found
    func nodeAdded(_ node: SCNNode, for anchor: ARPlaneAnchor) {
        let floor = createFloor(planeAnchor: anchor)
        floor.isHidden = !showPlaneOverlay
        addNode(floor, to: node, isFloor: true)
    }
    
    /// Image node AR anchor has been added to the scene
    ///
    /// - Parameters:
    ///   - node: node which was added
    ///   - anchor: AR image anchor which defines the image found
    func nodeAdded(_ node: SCNNode, for anchor: ARImageAnchor) {
        guard let selectedNode = selectedNode else { return }
        
        addNode(selectedNode, to: node)
    }
}

// MARK: - ARSCNViewDelegate
extension ViewController {
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        
        if let planeAnchor = anchor as? ARPlaneAnchor {
            nodeAdded(node, for: planeAnchor)
        } else if let imageAnchor = anchor as? ARImageAnchor {
            nodeAdded(node, for: imageAnchor)
        }
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }
        guard let planeNode = node.childNodes.first else { return }
        guard let plane = planeNode.geometry as? SCNPlane else { return }
        
        let center = planeAnchor.center
        planeNode.position = SCNVector3(center.x, 0, center.z)
        
        let extent = planeAnchor.extent
        plane.width = CGFloat(extent.x)
        plane.height = CGFloat(extent.z)

        self.counterLabel.text = String(self.placedNodes.compactMap {$0}.count)
    }
    
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        updateFocusSquare()
    }
}

// MARK: - Configuration Methods
extension ViewController {
    func reloadConfiguration(removeAnchors: Bool = true) {
        configuration.planeDetection = [.horizontal, .vertical]
        
        let images = ARReferenceImage.referenceImages(inGroupNamed: "AR Resources", bundle: nil)
        
        configuration.detectionImages = objectMode == .image ? images : nil
        
        let options: ARSession.RunOptions
        
        if removeAnchors {
            options = [.removeExistingAnchors]
            
            planeNodes.removeAll()
            
            placedNodes.forEach { $0?.removeFromParentNode() }
            placedNodes.removeAll()
            
        } else {
            options = []
        }
        
        sceneView.session.run(configuration, options: options)
    }
}

// MARK: - Physics Contact Methods
extension ViewController: SCNPhysicsContactDelegate {

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
    
        let nodeA = contact.nodeA
        let nodeB = contact.nodeB
        let numberA = Int(nodeA.name!)!
        let numberB = Int(nodeB.name!)!
        
        if numberA > numberB {
            nodeA.removeFromParentNode()
            placedNodes[numberA] = nil
        } else {
            nodeB.removeFromParentNode()
            placedNodes[numberB] = nil
        }
    }
}

// MARK: - Focus Square
extension ViewController {
    
    func updateFocusSquare() {
        
        switch objectMode {
        case .plane:
            focusSquare.unhide()
            // Perform hit testing only when ARKit tracking is in a good state.
            if let camera = sceneView.session.currentFrame?.camera, case .normal = camera.trackingState,
                let result = self.sceneView.smartHitTest(screenCenter) {
                
                self.sceneView.scene.rootNode.addChildNode(self.focusSquare)
                self.focusSquare.state = .detecting(hitTestResult: result, camera: camera)
                
            } else {
                self.focusSquare.state = .initializing
                self.sceneView.pointOfView?.addChildNode(self.focusSquare)
            }
        default:
            focusSquare.hide()
        }
    }
}

extension ARSCNView {
    func smartHitTest(_ point: CGPoint,
                      allowedAlignments: [ARPlaneAnchor.Alignment] = [.horizontal, .vertical]) -> ARHitTestResult? {
        
        // Perform the hit test.
        let results = hitTest(point, types: [.existingPlaneUsingGeometry, .estimatedVerticalPlane, .estimatedHorizontalPlane])
        
        // 1. Check for a result on an existing plane using geometry.
        if let existingPlaneUsingGeometryResult = results.first(where: { $0.type == .existingPlaneUsingGeometry }),
            let planeAnchor = existingPlaneUsingGeometryResult.anchor as? ARPlaneAnchor, allowedAlignments.contains(planeAnchor.alignment) {
            return existingPlaneUsingGeometryResult
        }

        // 2. As a final fallback, check for a result on estimated planes.
        let vResult = results.first(where: { $0.type == .estimatedVerticalPlane })
        let hResult = results.first(where: { $0.type == .estimatedHorizontalPlane })
        switch (allowedAlignments.contains(.horizontal), allowedAlignments.contains(.vertical)) {
        case (true, false):
            return hResult
        case (false, true):
            // Allow fallback to horizontal because we assume that objects meant for vertical placement
            // (like a picture) can always be placed on a horizontal surface, too.
            return vResult ?? hResult
        case (true, true):
            if hResult != nil && vResult != nil {
                return hResult!.distance < vResult!.distance ? hResult! : vResult!
            } else {
                return hResult ?? vResult
            }
        default:
            return nil
        }
    }
}

// MARK: - float4x4 extensions

extension float4x4 {
    /**
     Treats matrix as a (right-hand column-major convention) transform matrix
     and factors out the translation component of the transform.
     */
    var translation: float3 {
        get {
            let translation = columns.3
            return float3(translation.x, translation.y, translation.z)
        }
        set(newValue) {
            columns.3 = float4(newValue.x, newValue.y, newValue.z, columns.3.w)
        }
    }
    
    /**
     Factors out the orientation component of the transform.
     */
    var orientation: simd_quatf {
        return simd_quaternion(self)
    }
    
    /**
     Creates a transform matrix with a uniform scale factor in all directions.
     */
    init(uniformScale scale: Float) {
        self = matrix_identity_float4x4
        columns.0.x = scale
        columns.1.y = scale
        columns.2.z = scale
    }
}
