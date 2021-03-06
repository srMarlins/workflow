/*
 * Copyright 2019 Square Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.squareup.workflow.ui

import android.arch.lifecycle.ViewModelProviders
import android.os.Bundle
import android.support.v4.app.Fragment
import android.support.v4.app.FragmentActivity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import com.squareup.workflow.Workflow
import io.reactivex.BackpressureStrategy.LATEST
import io.reactivex.Flowable
import io.reactivex.Observable

/**
 * A [Fragment] that can run a workflow. Subclasses implement [onCreateWorkflow]
 * to configure themselves with a [Workflow], [ViewRegistry] and [inputs][Flowable].
 *
 * For a workflow with no inputs, or a static configuration, that's as simple as:
 *
 *    class HelloWorkflowFragment : WorkflowFragment<Unit, Unit>() {
 *      override fun onCreateWorkflow(): Config<Unit, Unit> {
 *        return Config(
 *            workflow = HelloWorkflow,
 *            viewRegistry = ViewRegistry(HelloFragmentCoordinator),
 *            input = Unit
 *        )
 *      }
 *    }
 *
 * A fragment to run a workflow whose configuration may need to be updated could
 * provide a method like this:
 *
 *   class HelloWorkflowFragment : WorkflowFragment<HelloInput, Unit>() {
 *     private val inputs = BehaviorSubject.createDefault(HelloInput.Fnord)
 *
 *     fun input(input: HelloInput) = inputs.onNext(input)
 *
 *     override fun onCreateWorkflow(): Config<HelloInput, Unit> {
 *       return Config(
 *           workflow = HelloWorkflow,
 *           viewRegistry = ViewRegistry(HelloFragmentCoordinator),
 *           inputs = inputs
 *       )
 *     }
 *   }
 */
@ExperimentalWorkflowUi
abstract class WorkflowFragment<InputT, OutputT : Any> : Fragment() {

  data class Config<InputT, OutputT : Any>(
    val workflow: Workflow<InputT, OutputT, Any>,
    val viewRegistry: ViewRegistry,
    val inputs: Flowable<InputT>
  ) {
    constructor(
      workflow: Workflow<InputT, OutputT, Any>,
      viewRegistry: ViewRegistry,
      inputs: Observable<InputT>
    ) : this(workflow, viewRegistry, inputs.toFlowable(LATEST))

    constructor(
      workflow: Workflow<InputT, OutputT, Any>,
      viewRegistry: ViewRegistry,
      input: InputT
    ) : this(workflow, viewRegistry, Observable.just(input))
  }

  private lateinit var _runner: WorkflowRunnerViewModel<OutputT>

  /**
   * Provides subclasses with access to the products of the running [Workflow].
   * Safe to call after [onActivityCreated].
   */
  protected val runner: WorkflowRunner<OutputT> get() = _runner

  /**
   * Called from [onActivityCreated], so it should be safe for implementations
   * to call [getActivity].
   */
  protected abstract fun onCreateWorkflow(): Config<InputT, OutputT>

  final override fun onCreateView(
    inflater: LayoutInflater,
    container: ViewGroup?,
    savedInstanceState: Bundle?
  ): View? {
    return WorkflowLayout(inflater.context)
  }

  override fun onActivityCreated(savedInstanceState: Bundle?) {
    super.onActivityCreated(savedInstanceState)

    val (workflow, viewRegistry, inputs) = onCreateWorkflow()
    val factory =
      WorkflowRunnerViewModel.Factory(workflow, viewRegistry, inputs, savedInstanceState)

    // We use an Android lifecycle ViewModel to shield ourselves from configuration changes.
    // ViewModelProviders.of() uses the factory to instantiate a new instance only
    // on the first call for this fragment, and it stores that instance for repeated use
    // until this fragment is finished.

    @Suppress("UNCHECKED_CAST")
    _runner = ViewModelProviders.of(this, factory)[WorkflowRunnerViewModel::class.java]
        as WorkflowRunnerViewModel<OutputT>

    (view as WorkflowLayout).setWorkflowRunner(runner)
  }

  override fun onSaveInstanceState(outState: Bundle) {
    super.onSaveInstanceState(outState)
    _runner.onSaveInstanceState(outState)
  }

  /**
   * If your workflow needs to manage the back button, override [FragmentActivity.onBackPressed]
   * and call this method, and have your views or coordinators use [HandlesBack].
   *
   * e.g.:
   *
   *    override fun onBackPressed() {
   *      val workflowFragment =
   *        supportFragmentManager.findFragmentByTag(MY_WORKFLOW) as? WorkflowFragment<*, *>
   *      if (workflowFragment?.onBackPressed() != true) super.onBackPressed()
   *    }
   */
  fun onBackPressed(): Boolean {
    return isVisible && HandlesBack.Helper.onBackPressed(view!!)
  }
}
