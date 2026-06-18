package db.demo.reader

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication
import org.springframework.data.web.config.EnableSpringDataWebSupport
import org.springframework.data.web.config.EnableSpringDataWebSupport.PageSerializationMode


@SpringBootApplication
@EnableSpringDataWebSupport(pageSerializationMode = PageSerializationMode.VIA_DTO)
class ReaderApp {

  companion object {
    @JvmStatic
    fun main(args: Array<String>) {
      runApplication<ReaderApp>(*args)
    }
  }
}