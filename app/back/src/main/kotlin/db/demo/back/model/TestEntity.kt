package db.demo.back.model


import jakarta.persistence.Entity
import jakarta.persistence.GeneratedValue
import jakarta.persistence.GenerationType
import jakarta.persistence.Id


@Entity
class TestEntity {

  @Id
  @GeneratedValue(strategy = GenerationType.AUTO)
  var id: Long? = null

  var message: String? = null

  var calculated: Double? = null
}
