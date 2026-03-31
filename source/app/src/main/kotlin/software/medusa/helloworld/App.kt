package software.medusa.helloworld

import com.google.cloud.firestore.FirestoreOptions
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.Serializable

@Serializable
data class CounterResponse(val count: Long)

fun main() {
    val port = System.getenv("PORT")?.toIntOrNull() ?: 8080
    embeddedServer(Netty, port = port, module = Application::module).start(wait = true)
}

fun Application.module() {
    install(ContentNegotiation) {
        json()
    }

    val firestore = FirestoreOptions.getDefaultInstance().service

    routing {
        get("/") {
            call.respondText("Hello, World!")
        }

        post("/counter/increment") {
            val counterRef = firestore.collection("counters").document("main")

            val newCount = firestore.runTransaction { transaction ->
                val snapshot = transaction.get(counterRef).get()
                val currentCount = snapshot.getLong("value") ?: 0L
                val updatedCount = currentCount + 1
                transaction.set(counterRef, mapOf("value" to updatedCount))
                updatedCount
            }.get()

            call.respond(CounterResponse(count = newCount))
        }

        get("/counter") {
            val counterRef = firestore.collection("counters").document("main")
            val snapshot = counterRef.get().get()
            val count = snapshot.getLong("value") ?: 0L
            call.respond(CounterResponse(count = count))
        }
    }
}
