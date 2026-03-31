package software.medusa.helloworld

import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.install
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import io.ktor.server.testing.testApplication
import kotlin.test.Test
import kotlin.test.assertEquals

class AppTest {
    @Test
    fun testRoot(): Unit = testApplication {
        application {
            install(ContentNegotiation) {
                json()
            }

            routing {
                get("/") {
                    call.respondText("Hello, World!")
                }
            }
        }

        client.get("/").apply {
            assertEquals(HttpStatusCode.OK, status)
            assertEquals("Hello, World!", bodyAsText())
        }
    }
}
