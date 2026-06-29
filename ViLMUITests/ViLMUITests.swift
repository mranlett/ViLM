import XCTest

final class ViLMUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testSidebarNavigation() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Wait for the app to load and the sidebar to be visible
        // If the user hasn't selected a library yet, the "Open Library" button might be visible.
        // We handle both states defensively.
        
        let openLibraryButton = app.buttons["Open Library"]
        if openLibraryButton.exists {
            // Cannot proceed with full navigation test without a library selected.
            // But we can assert the welcome screen loads properly.
            XCTAssertTrue(openLibraryButton.isHittable, "Open Library button should be clickable on welcome screen.")
            return
        }
        
        // Assuming a library is loaded, verify the main sidebar navigation links exist
        let actorsGalleryLink = app.buttons["Actors Gallery"]
        let allAssetsLink = app.buttons["All Assets"]
        let tagsGalleryLink = app.buttons["Tags Gallery"]
        
        // We use buttons because NavigationLinks in Sidebar often render as buttons in XCUITest
        // If they render as static texts, we can fall back to checking static texts.
        
        // Tap Actors Gallery
        if actorsGalleryLink.exists {
            actorsGalleryLink.tap()
            // Verify the title changed to Actors Gallery
            XCTAssertTrue(app.navigationBars["Actors Gallery"].exists || app.staticTexts["Actors Gallery"].exists)
        }
        
        // Tap Tags Gallery
        if tagsGalleryLink.exists {
            tagsGalleryLink.tap()
            XCTAssertTrue(app.navigationBars["Tags Gallery"].exists || app.staticTexts["Tags Gallery"].exists)
        }
        
        // Tap All Assets
        if allAssetsLink.exists {
            allAssetsLink.tap()
            XCTAssertTrue(app.navigationBars["All Assets"].exists || app.staticTexts["All Assets"].exists || app.staticTexts["All"].exists)
        }
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
