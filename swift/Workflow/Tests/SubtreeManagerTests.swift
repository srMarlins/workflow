import XCTest
@testable import Workflow
import ReactiveSwift
import Result


final class SubtreeManagerTests: XCTestCase {

    func test_maintainsChildrenBetweenRenderPasses() {
        let manager = WorkflowNode<ParentWorkflow>.SubtreeManager()
        XCTAssertTrue(manager.childWorkflows.isEmpty)

        _ = manager.render { context -> TestViewModel in
            return context.render(
                workflow: TestWorkflow(),
                key: "",
                outputMap: { _ in AnyWorkflowAction.identity })
        }

        XCTAssertEqual(manager.childWorkflows.count, 1)
        let child = manager.childWorkflows.values.first!

        _ = manager.render { context -> TestViewModel in
            return context.render(
                workflow: TestWorkflow(),
                key: "",
                outputMap: { _ in AnyWorkflowAction.identity })
        }

        XCTAssertEqual(manager.childWorkflows.count, 1)
        XCTAssertTrue(manager.childWorkflows.values.first === child)

    }

    func test_removesUnusedChildrenAfterRenderPasses() {
        let manager = WorkflowNode<ParentWorkflow>.SubtreeManager()
        _ = manager.render { context -> TestViewModel in
            return context.render(
                workflow: TestWorkflow(),
                key: "",
                outputMap: { _ in AnyWorkflowAction.identity })
        }

        XCTAssertEqual(manager.childWorkflows.count, 1)

        _ = manager.render { context -> Void in

        }

        XCTAssertTrue(manager.childWorkflows.isEmpty)
    }

    func test_emitsChildEvents() {

        let manager = WorkflowNode<ParentWorkflow>.SubtreeManager()

        var events: [AnyWorkflowAction<ParentWorkflow>] = []

        manager.onUpdate = {
            switch $0 {
            case .update(let event, _):
                events.append(event)
            default:
                break
            }
        }

        let viewModel = manager.render { context -> TestViewModel in
            return context.render(
                workflow: TestWorkflow(),
                key: "",
                outputMap: { _ in AnyWorkflowAction.identity })
        }
        manager.enableEvents()

        viewModel.onTap()
        viewModel.onTap()

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(events.count, 2)

    }

    func test_emitsChangeEvents() {

        let manager = WorkflowNode<ParentWorkflow>.SubtreeManager()

        var changeCount = 0

        manager.onUpdate = { _ in
            changeCount += 1
        }

        let viewModel = manager.render { context -> TestViewModel in
            return context.render(
                workflow: TestWorkflow(),
                key: "",
                outputMap: { _ in AnyWorkflowAction.identity })
        }
        manager.enableEvents()

        viewModel.onToggle()
        viewModel.onToggle()

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(changeCount, 2)
    }
    
    func test_invalidatesContextAfterRender() {
        let manager = WorkflowNode<ParentWorkflow>.SubtreeManager()
        
        var escapingContext: RenderContext<ParentWorkflow>! = nil
        
        _ = manager.render { context -> TestViewModel in
            XCTAssertTrue(context.isValid)
            escapingContext = context
            return context.render(
                workflow: TestWorkflow(),
                key: "",
                outputMap: { _ in AnyWorkflowAction.identity })
        }
        manager.enableEvents()

        XCTAssertFalse(escapingContext.isValid)
    }

    // A worker declared on a first `render` pass that is not on a subsequent should have the work cancelled.
    func test_cancelsWorkers() {
        struct WorkerWorkflow: Workflow {
            var startExpectation: XCTestExpectation
            var endExpectation: XCTestExpectation

            enum State {
                case notWorking
                case working
            }

            func makeInitialState() -> WorkerWorkflow.State {
                return .notWorking
            }

            func workflowDidChange(from previousWorkflow: WorkerWorkflow, state: inout WorkerWorkflow.State) {

            }

            func render(state: WorkerWorkflow.State, context: RenderContext<WorkerWorkflow>) -> Bool {
                switch state {
                case .notWorking:
                    return false
                case .working:
                    context.awaitResult(
                        for: ExpectingWorker(
                            startExpectation: startExpectation,
                            endExpectation: endExpectation),
                        outputMap: { output -> AnyWorkflowAction<WorkerWorkflow> in
                            return AnyWorkflowAction.identity
                        })
                    return true
                }
            }

            struct ExpectingWorker: Worker {
                var startExpectation: XCTestExpectation
                var endExpectation: XCTestExpectation

                typealias Output = Void

                func run() -> SignalProducer<Void, NoError> {
                    return SignalProducer<Void, NoError>({ [weak startExpectation, weak endExpectation] (observer, lifetime) in
                        lifetime.observeEnded {
                            endExpectation?.fulfill()
                        }

                        startExpectation?.fulfill()
                    })
                }

                func isEquivalent(to otherWorker: WorkerWorkflow.ExpectingWorker) -> Bool {
                    return true
                }
            }
        }

        let startExpectation = XCTestExpectation()
        let endExpectation = XCTestExpectation()
        let manager = WorkflowNode<WorkerWorkflow>.SubtreeManager()

        let isRunning = manager.render({ context -> Bool in
            WorkerWorkflow(
                startExpectation: startExpectation,
                endExpectation: endExpectation)
                .render(
                    state: .working,
                    context: context)
        })

        XCTAssertEqual(true, isRunning)
        wait(for: [startExpectation], timeout: 1.0)

        let isStillRunning = manager.render({ context -> Bool in
            WorkerWorkflow(
                startExpectation: startExpectation,
                endExpectation: endExpectation)
                .render(
                    state: .notWorking,
                    context: context)
        })

        XCTAssertFalse(isStillRunning)
        wait(for: [endExpectation], timeout: 1.0)
    }

    func test_subscriptionsUnsubscribe() {
        struct SubscribingWorkflow: Workflow {
            var signal: Signal<Void, NoError>?

            struct State {}

            func makeInitialState() -> SubscribingWorkflow.State {
                return State()
            }

            func workflowDidChange(from previousWorkflow: SubscribingWorkflow, state: inout SubscribingWorkflow.State) {
            }

            func render(state: SubscribingWorkflow.State, context: RenderContext<SubscribingWorkflow>) -> Bool {
                if let signal = signal {
                    context.subscribe(signal: signal.map({ _ -> AnyWorkflowAction<SubscribingWorkflow> in
                        return AnyWorkflowAction.identity
                    }))
                    return true
                } else {
                    return false
                }
            }
        }

        let emittedExpectation = XCTestExpectation()
        let notEmittedExpectation = XCTestExpectation()
        notEmittedExpectation.isInverted = true

        let manager = WorkflowNode<SubscribingWorkflow>.SubtreeManager()
        manager.onUpdate = { output in
            emittedExpectation.fulfill()
        }

        let (signal, observer) = Signal<Void, NoError>.pipe()

        let isSubscribing = manager.render { context -> Bool in
            SubscribingWorkflow(
                signal: signal)
                .render(
                    state: SubscribingWorkflow.State(),
                    context: context)
        }
        manager.enableEvents()

        XCTAssertTrue(isSubscribing)
        observer.send(value: ())
        wait(for: [emittedExpectation], timeout: 1.0)

        manager.onUpdate = { output in
            notEmittedExpectation.fulfill()
        }

        let isStillSubscribing = manager.render { context -> Bool in
            SubscribingWorkflow(
                signal: nil)
                .render(
                    state: SubscribingWorkflow.State(),
                    context: context)
        }
        manager.enableEvents()

        XCTAssertFalse(isStillSubscribing)

        observer.send(value: ())
        wait(for: [notEmittedExpectation], timeout: 1.0)
    }
}


fileprivate struct TestViewModel {
    var onTap: () -> Void
    var onToggle: () -> Void
}

fileprivate struct ParentWorkflow: Workflow {
    struct State {}
    typealias Event = TestWorkflow.Output
    typealias Output = Never

    func makeInitialState() -> State {
        return State()
    }

    func workflowDidChange(from previousWorkflow: ParentWorkflow, state: inout State) {

    }

    func render(state: State, context: RenderContext<ParentWorkflow>) -> Never {
        fatalError()
    }
}


fileprivate struct TestWorkflow: Workflow {

    enum State {
        case foo
        case bar
    }

    enum Event: WorkflowAction {
        typealias WorkflowType = TestWorkflow

        case changeState
        case sendOutput

        func apply(toState state: inout TestWorkflow.State) -> TestWorkflow.Output? {
            switch self {
            case .changeState:
                switch state {
                case .foo: state = .bar
                case .bar: state = .foo
                }
                return nil
            case .sendOutput:
                return .helloWorld
            }
        }
    }

    enum Output {
        case helloWorld
    }

    func makeInitialState() -> State {
        return .foo
    }

    func workflowDidChange(from previousWorkflow: TestWorkflow, state: inout State) {

    }

    func render(state: State, context: RenderContext<TestWorkflow>) -> TestViewModel {

        let sink = context.makeSink(of: Event.self)

        return TestViewModel(
            onTap: { sink.send(.sendOutput) },
            onToggle: { sink.send(.changeState) })
    }

}
