package db.demo.reader.web

import db.demo.logger
import db.demo.reader.model.TestEntity
import db.demo.reader.repository.TestRepository
import io.swagger.v3.oas.annotations.Operation
import org.springdoc.core.annotations.ParameterObject
import org.springframework.data.domain.Page
import org.springframework.data.domain.Pageable
import org.springframework.data.web.PageableDefault
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/v1/testEntity")
class TestEntityController(
  val testRepository: TestRepository,
) {

  private val log = logger()

  @Operation(summary = "Get test entities")
  @GetMapping
  fun list(
    @ParameterObject @PageableDefault(size = 20) pageable: Pageable,
  ): Page<TestEntity> {
    return testRepository.findAll(pageable).also { log.info("Fetched ${it.totalElements} test entities") }
  }
}
