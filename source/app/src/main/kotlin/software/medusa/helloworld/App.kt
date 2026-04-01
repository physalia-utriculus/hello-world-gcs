package software.medusa.helloworld

import com.google.cloud.storage.BlobId
import com.google.cloud.storage.BlobInfo
import com.google.cloud.storage.StorageException
import com.google.cloud.storage.StorageOptions
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

    val storage = StorageOptions.getDefaultInstance().service
    val bucketName = System.getenv("GCS_BUCKET_NAME")
        ?: error("GCS_BUCKET_NAME environment variable is not set")
    val counterBlobId = BlobId.of(bucketName, "counter/main")

    routing {
        get("/") {
            call.respondText("Hello, World!")
        }

        post("/counter/increment") {
            val newCount = incrementCounter(storage, counterBlobId)
            call.respond(CounterResponse(count = newCount))
        }

        get("/counter") {
            val blob = storage.get(counterBlobId)
            val count = blob?.getContent()?.toString(Charsets.UTF_8)?.toLongOrNull() ?: 0L
            call.respond(CounterResponse(count = count))
        }
    }
}

/**
 * Atomically increments the counter stored in GCS using optimistic concurrency via
 * generation-match preconditions. Retries on conflict until the write succeeds.
 */
private fun incrementCounter(
    storage: com.google.cloud.storage.Storage,
    blobId: BlobId,
): Long {
    while (true) {
        val existing = storage.get(blobId)
        val currentCount = existing?.getContent()?.toString(Charsets.UTF_8)?.toLongOrNull() ?: 0L
        val newCount = currentCount + 1
        val newContent = newCount.toString().toByteArray(Charsets.UTF_8)

        try {
            if (existing == null) {
                // Object does not exist yet — create it, but only if generation is still 0
                val blobInfo = BlobInfo.newBuilder(blobId).setContentType("text/plain").build()
                storage.create(
                    blobInfo,
                    newContent,
                    com.google.cloud.storage.Storage.BlobTargetOption.doesNotExist(),
                )
            } else {
                // Object exists — overwrite only if generation has not changed
                existing.writer(
                    com.google.cloud.storage.Storage.BlobWriteOption.generationMatch()
                ).use { writer ->
                    writer.write(java.nio.ByteBuffer.wrap(newContent))
                }
            }
            return newCount
        } catch (e: StorageException) {
            if (e.code == 412 || e.code == 409) {
                // Precondition failed (412) or conflict (409) — another writer raced us; retry
                continue
            }
            throw e
        }
    }
}
