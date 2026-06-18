package db.demo.front.web

import org.springframework.stereotype.Controller
import org.springframework.web.bind.annotation.GetMapping

@Controller
class IndexController {

  @GetMapping("/")
  fun index(): String {
    return "redirect:/swagger-ui.html"
  }
}
