package db.demo.front.web

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import db.demo.front.service.ProcessEventService
import db.demo.model.TestCommand
import db.demo.rnd
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.media.Schema
import jakarta.validation.constraints.PositiveOrZero
import org.springframework.validation.annotation.Validated
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/v1/command")
@Validated
class IngestCommandController(
  private val processEventService: ProcessEventService,
) {

  @Operation(summary = "Post test command")
  @PostMapping
  fun postEvent(@Validated @RequestBody request: CommandRequest) {
    processEventService.processCommand(
      TestCommand(
        message = request.message,
        loadFront = request.loadFront,
        loadBack = request.loadBack,
        calculated = rnd.nextDouble()
      )
    )
  }
}

@JsonIgnoreProperties(ignoreUnknown = true)
data class CommandRequest(
  @field:Schema(
    description = "Optional message",
    example = "Hello world",
    nullable = true,
  )
  val message: String? = null,

  @field:Schema(
    description = "Generate load on front",
    example = "100",
  )
  @field:PositiveOrZero
  val loadFront: Int = 0,

  @field:Schema(
    description = "Generate load on back",
    example = "100",
  )
  @field:PositiveOrZero
  val loadBack: Int = 0,
)
