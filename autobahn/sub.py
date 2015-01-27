from autobahn.twisted.wamp import ApplicationSession, ApplicationRunner
from twisted.internet.defer import inlineCallbacks


class MySubscriber(ApplicationSession):

   @inlineCallbacks
   def onJoin(self, details):
      print("session ready")

      def oncounter(count):
         print("event received: {0}", count)

      try:
         yield self.subscribe(oncounter, u'com.zzish.testroom')
         print("subscribed to topic")
      except Exception as e:
         print("could not subscribe to topic: {0}".format(e))

if __name__ == '__main__':
   runner = ApplicationRunner(url = u"ws://localhost:8080/ws", realm = u"realm1")
   runner.run(MySubscriber)
