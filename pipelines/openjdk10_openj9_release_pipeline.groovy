println "building ${JDK_TAG}"

def buildPlatforms = ['Linux', 'zLinux', 'ppc64le', 'AIX', "Windows"]
def buildMaps = [:]
def PIPELINE_TIMESTAMP = new Date(currentBuild.startTimeInMillis).format("yyyyMMddHHmm")

buildMaps['Linux'] = [test:['openjdktest', 'systemtest', 'externaltest'], ArchOSs:'x86-64_linux']
buildMaps['zLinux'] = [test:['openjdktest', 'systemtest'], ArchOSs:'s390x_linux']
buildMaps['ppc64le'] = [test:['openjdktest', 'systemtest'], ArchOSs:'ppc64le_linux']
buildMaps['AIX'] = [test:false, ArchOSs:'ppc64_aix']
buildMaps['Windows'] = [test:['openjdktest'], ArchOSs:'x86-64_windows']
def typeTests = ['openjdktest', 'systemtest']

def jobs = [:]
for ( int i = 0; i < buildPlatforms.size(); i++ ) {
	def index = i
	def platform = buildPlatforms[index]
	def archOS = buildMaps[platform].ArchOSs
	jobs[platform] = {
		def buildJob
		def buildJobNum
		def checksumJob
		stage('build') {
			buildJob = build job: "openjdk10_openj9_build_${archOS}",
					parameters: [string(name: 'BRANCH', value: "$ALT_BRANCH"),
					string(name: 'PIPELINE_TIMESTAMP', value: "${PIPELINE_TIMESTAMP}")]
			buildJobNum = buildJob.getNumber()
		}
		if (buildMaps[platform].test) {
			stage('test') {
				buildMaps[platform].test.each {
					build job:"openjdk10_j9_${it}_${archOS}",
							propagate: false,
							parameters: [string(name: 'UPSTREAM_JOB_NUMBER', value: "${buildJobNum}"),
									string(name: 'UPSTREAM_JOB_NAME', value: "openjdk10_openj9_build_${archOS}")]
				}
			}
		}
	}
}
parallel jobs

stage('checksums') {
	checksumJob = build job: 'openjdk10_openj9_build_checksum',
		parameters: [string(name: 'UPSTREAM_JOB_NUMBER', value: "${buildJobNum}"),
			     string(name: 'UPSTREAM_JOB_NAME', value: "openjdk10_openj9_build_${archOS}"),
			     string(name: 'PRODUCT', value: 'releases')]
}
stage('publish releases') {
	build job: 'openjdk_release_tool',
		parameters: [string(name: 'REPO', value: 'releases'),
			     string(name: 'TAG', value: "${JDK_TAG}"),
			     string(name: 'VERSION', value: 'jdk10-openj9'),
			     string(name: 'CHECKSUM_JOB_NAME', value: "openjdk10_openj9_build_checksum"),
			     string(name: 'CHECKSUM_JOB_NUMBER', value: "${checksumJob.getNumber()}")]
}
