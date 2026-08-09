// Versionen bewusst identisch zum Flutter-Projekt nebenan (android/) — dann
// liegen Plugin und Gradle-Verteilung schon im Cache und der Build braucht
// keinen Download.
plugins {
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}
